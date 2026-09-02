import 'dart:async';
import 'dart:convert';
import 'dart:io';


import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// [NEW 2026-09-02] Netchat AI — chat with the PowerX agent and analyse files.
///
/// Transport (verified live): GET
///   https://minis-yzdb.onrender.com/v1/chat/completions
///     ?token=<TOKEN>
///     &payload={"model":"powerx-agent","messages":[...]}
///
/// Multimodal file support uses the content-part format:
///   {"role":"user","content":[
///      {"type":"text","text":"What is in this image?"},
///      {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}
///
/// The API token can be overridden by the admin from the Admin Panel; it is
/// stored in the Supabase `app_settings` table under key `netchat_ai_token`.
class NetchatAiService {
  NetchatAiService._();

  static const String baseUrl =
      'https://minis-yzdb.onrender.com/v1/chat/completions';
  static const String defaultToken =
      'px_DfwhyZiC3ZW2nde8U18fQZGqHbVzunOTUU1ijdq5';
  static const String model = 'powerx-agent';
  static const String settingsKey = 'netchat_ai_token';

  static String? _cachedToken;
  static DateTime? _cachedAt;

  /// Invalidate the in-memory token cache (called after admin saves a new one).
  static void invalidateCache() {
    _cachedToken = null;
    _cachedAt = null;
  }

  /// Resolve the active token: app_settings override > built-in default.
  static Future<String> resolveToken() async {
    if (_cachedToken != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < const Duration(minutes: 10)) {
      return _cachedToken!;
    }
    String token = defaultToken;
    try {
      final row = await Supabase.instance.client
          .from('app_settings')
          .select('value')
          .eq('key', settingsKey)
          .maybeSingle();
      if (row != null) {
        var v = row['value'];
        // value is JSONB; may arrive as String already or Map-wrapped.
        if (v is Map) v = v.toString();
        final s = (v ?? '').toString().replaceAll(RegExp(r'^"|"$'), '').trim();
        if (s.isNotEmpty) token = s;
      }
    } catch (_) {
      // Offline / RLS hiccup → fall back to the shipped default so the AI
      // keeps working regardless of Supabase state (UI independence rule #1).
    }
    _cachedToken = token;
    _cachedAt = DateTime.now();
    return token;
  }

  /// Admin: persist a new token into app_settings (UPDATE-only policy).
  static Future<void> setAdminToken(String token) async {
    // PATCH works on existing rows even when INSERT is RLS-blocked. Ensure
    // the row exists first by attempting an update; empty result means the
    // row was never created → surface a clear error.
    final res = await Supabase.instance.client
        .from('app_settings')
        .update({'value': jsonEncode(token)})
        .eq('key', settingsKey)
        .select('key');
    if ((res as List).isEmpty) {
      throw Exception(
          'app_settings/$settingsKey row missing — run once in SQL editor:\n'
          "insert into public.app_settings(key,value) values ('$settingsKey','\"\"') on conflict (key) do nothing;");
    }
    invalidateCache();
  }

  /// Send a chat turn and return the assistant's text.
  ///
  /// [attachments] are pre-encoded data-URI parts (images) or extracted text
  /// (documents) built by the UI layer via [buildFileParts].
  static Future<String> ask({
    required List<Map<String, dynamic>> history,
    required String userText,
    List<Map<String, dynamic>> extraContentParts = const [],
    bool includeUserTextInContent = true,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final token = await resolveToken();

    final messages = <Map<String, dynamic>>[];
    for (final m in history) {
      messages.add({
        'role': m['role'],
        'content': m['content'],
      });
    }
    final content = <Map<String, dynamic>>[
      if (includeUserTextInContent || userText.isNotEmpty)
        {'type': 'text', 'text': userText.isEmpty ? 'Analyse the attached file(s).' : userText},
      ...extraContentParts,
    ];
    messages.add({
      'role': 'user',
      // The API accepts both plain strings and content-part arrays; verified
      // live with a base64 image part.
      'content': content.length == 1 && content.first['type'] == 'text'
          ? content.first['text']
          : content,
    });

    final payload = jsonEncode({'model': model, 'messages': messages});
    final uri = Uri.parse('$baseUrl?token=${Uri.encodeComponent(token)}'
        '&payload=${Uri.encodeComponent(payload)}');

    late http.Response resp;
    try {
      resp = await http.get(uri).timeout(timeout);
    } on SocketException {
      rethrow;
    } on TimeoutException {
      throw Exception('Netchat AI timed out — the server may be sleeping. Try again in a few seconds.');
    }

    if (resp.statusCode != 200) {
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (body.contains('upstream unavailable')) {
        throw Exception('AI upstream is waking up — retry in ~20 seconds.');
      }
      throw Exception('AI error (${resp.statusCode}): ${body.length > 200 ? body.substring(0, 200) : body}');
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('AI returned no answer.');
    }
    final msg = (choices.first as Map)['message'] as Map?;
    final text = (msg?['content'] ?? '').toString();
    if (text.trim().isEmpty) throw Exception('AI returned an empty answer.');
    return text;
  }

  static const _imageExts = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};
  static const _textExts = {
    'txt', 'md', 'csv', 'json', 'log', 'xml', 'yaml', 'yml', 'html', 'dart',
    'js', 'ts', 'py', 'java', 'kt', 'css', 'sql', 'sh',
  };
  static const maxImageBytes = 4 * 1024 * 1024; // 4 MB raw
  static const maxDocChars = 12000; // cap extracted text size

  /// Convert picked files into AI content parts.
  /// Returns (parts, notesForUser). Images become data URIs; PDFs get their
  /// text extracted; plain-text files are inlined (truncated). Unsupported
  /// types are skipped with a note.
  static Future<({List<Map<String, dynamic>> parts, List<String> notes})>
      buildFileParts(List<File> files) async {
    final parts = <Map<String, dynamic>>[];
    final notes = <String>[];

    for (final f in files) {
      final ext = p.extension(f.path).replaceFirst('.', '').toLowerCase();
      final name = p.basename(f.path);
      try {
        final size = await f.length();
        if (_imageExts.contains(ext)) {
          if (size > maxImageBytes) {
            notes.add('$name skipped (>4MB image)');
            continue;
          }
          final bytes = await f.readAsBytes();
          final mime = ext == 'jpg' || ext == 'jpeg'
              ? 'image/jpeg'
              : ext == 'png'
                  ? 'image/png'
                  : ext == 'webp'
                      ? 'image/webp'
                      : ext == 'gif'
                          ? 'image/gif'
                          : 'image/bmp';
          final b64 = base64Encode(bytes);
          parts.add({
            'type': 'image_url',
            'image_url': {'url': 'data:$mime;base64,$b64'},
          });
        } else if (ext == 'pdf') {
          if (size > 10 * 1024 * 1024) {
            notes.add('$name skipped (>10MB PDF)');
            continue;
          }
          final text = await _extractPdfText(f);
          if (text.trim().isEmpty) {
            notes.add('$name has no extractable text (scanned PDF?)');
          } else {
            parts.add({
              'type': 'text',
              'text': '[File: $name]\n${_cap(text)}',
            });
          }
        } else if (_textExts.contains(ext)) {
          final raw = await f.readAsString();
          parts.add({
            'type': 'text',
            'text': '[File: $name]\n${_cap(raw)}',
          });
        } else {
          notes.add('$name skipped (unsupported type .$ext)');
        }
      } catch (e) {
        notes.add('$name failed to read: $e');
      }
    }
    return (parts: parts, notes: notes);
  }

  static String _cap(String s) =>
      s.length <= maxDocChars ? s : '${s.substring(0, maxDocChars)}\n…(truncated)';

  static Future<String> _extractPdfText(File f) async {
    final doc = PdfDocument(inputBytes: await f.readAsBytes());
    try {
      final pages = doc.pages.count;
      // Syncfusion's extractor works on page ranges (0-based, inclusive).
      final text = PdfTextExtractor(doc).extractText(
        startPageIndex: 0,
        endPageIndex: (pages < 10 ? pages : 10) - 1,
      );
      return text;
    } finally {
      doc.dispose();
    }
  }
}
