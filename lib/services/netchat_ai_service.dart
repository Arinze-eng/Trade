import 'dart:async';
import 'dart:convert';
import 'dart:io';


import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// [NEW 2026-09-02] Netchat AI — chat with the PowerX agent and analyse files.
///
/// Transport (verified live): POST
///   https://minis-yzdb.onrender.com/v1/chat/completions?token=<TOKEN>
///   with JSON body {"model":"powerx-agent","messages":[...]}
///
/// [FIX 2026-09-03] Switched from GET ?payload=<json> to POST with the payload
/// in the body. The old approach put the whole base64 image/PDF into the URL,
/// which broke large attachments (image / PDF / ZIP "not working"). Body-based
/// transport has no URL-length ceiling for large files.
///
/// Multimodal file support uses the content-part format:
///   {"role":"user","content":[
///      {"type":"text","text":"What is in this image?"},
///      {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}
///
/// Supported attachments: images (jpg/png/webp/gif/bmp), PDF (text-extracted),
/// plain-text, and ZIP/TAR archives (readable entries inlined + listing).
///
/// The API token can be overridden by the admin from the Admin Panel; it is
/// stored in the Supabase `app_settings` table under key `netchat_ai_token`.
class NetchatAiService {
  NetchatAiService._();

  static const String baseUrl =
      'https://minis-yzdb.onrender.com/v1/chat/completions';
  // [UPDATE 2026-09-03] Active PowerX token (rotated by owner).
  static const String defaultToken =
      'px_SbvVuEjLprdhclq03B8qrVaHGWZPFo04H0u9vWDT';
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

  /// Admin: persist a new token into app_settings (INSERT-ON-CONFLICT so the
  /// first save works even when the row does not exist yet — previously an
  /// UPDATE-only save failed with "row missing", which is what the Admin panel
  /// was showing).
  static Future<void> setAdminToken(String token) async {
    final val = jsonEncode(token);
    // INSERT ... ON CONFLICT (key) DO UPDATE — works for missing OR existing
    // rows and is not blocked by RLS as long as the table exposes an
    // authenticated UPDATE policy (or the anon/authenticated role can write).
    final res = await Supabase.instance.client
        .from('app_settings')
        .upsert(
          {'key': settingsKey, 'value': val},
          onConflict: 'key',
        )
        .select('key');
    if ((res as List).isEmpty) {
      throw Exception('Failed to write Netchat AI token.');
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

    // [FIX 2026-09-03] Send the payload as a JSON POST BODY rather than a URL
    // query parameter. The previous GET ?token=...&payload=<json> approach put
    // the entire (potentially multi-MB) base64 image/document into the URL,
    // which blew past URL-length limits → "not working / error" for image, PDF
    // and ZIP attachments. This follows the endpoint's documented chat payload
    // shape: {"model","messages":[...]}.
    final uri = Uri.parse('$baseUrl?token=${Uri.encodeComponent(token)}');

    late http.Response resp;
    try {
      resp = await http
          .post(uri,
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: payload)
          .timeout(timeout);
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
  static const _archiveExts = {'zip', 'rar', '7z', 'tar', 'gz'};
  static const maxImageBytes = 4 * 1024 * 1024; // 4 MB raw
  static const maxDocChars = 12000; // cap extracted text size
  static const maxZipBytes = 15 * 1024 * 1024; // 15 MB raw archive
  static const maxZipEntries = 50; // cap in-archive entries

  /// Convert picked files into AI content parts.
  /// Returns (parts, notesForUser). Images become data URIs; PDFs get their
  /// text extracted; plain-text files are inlined (truncated). ZIP/archive
  /// files are inspected — readable text entries are inlined (truncated) or
  /// the file listing is summarised so the model can work with them. Broken or
  /// unsupported types are skipped with a note (never a hard failure).
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
        } else if (_archiveExts.contains(ext)) {
          // [NEW 2026-09-03] ZIP/archive support: don't silently drop them.
          if (size > maxZipBytes) {
            notes.add('$name skipped (>15MB archive)');
            continue;
          }
          final built = await _buildArchivePart(f, name, ext);
          if (built.part != null) parts.add(built.part!);
          if (built.note != null) notes.add(built.note!);
        } else {
          notes.add('$name skipped (unsupported type .$ext)');
        }
      } catch (e) {
        notes.add('$name failed to read: $e');
      }
    }
    return (parts: parts, notes: notes);
  }

  /// Inspect a ZIP/TAR archive and turn it into a single text part: readable
  /// text entries are inlined (capped), everything else becomes a listing.
  static Future<({Map<String, dynamic>? part, String? note})>
      _buildArchivePart(File f, String name, String ext) async {
    try {
      final bytes = await f.readAsBytes();
      final entries = <(String, String)>[]; // (entryName, text)

      if (ext == 'zip') {
        final archive = ZipDecoder().decodeBytes(bytes);
        var count = 0;
        for (final entry in archive) {
          if (count >= maxZipEntries) break;
          if (!entry.isFile) continue;
          count++;
          final entryExt = p.extension(entry.name)
              .replaceFirst('.', '')
              .toLowerCase();
          if (_textExts.contains(entryExt)) {
            final text = utf8.decode(entry.content as List<int>,
                allowMalformed: true);
            if (text.trim().isNotEmpty) entries.add((entry.name, text));
          }
        }
      } else if (ext == 'tar' || ext == 'gz') {
        final archive = TarDecoder().decodeBytes(bytes);
        var count = 0;
        for (final entry in archive) {
          if (count >= maxZipEntries) break;
          if (!entry.isFile) continue;
          count++;
          final entryExt = p.extension(entry.name)
              .replaceFirst('.', '')
              .toLowerCase();
          if (_textExts.contains(entryExt)) {
            final text = utf8.decode(entry.content as List<int>,
                allowMalformed: true);
            if (text.trim().isNotEmpty) entries.add((entry.name, text));
          }
        }
      } else {
        // rar / 7z — the archive package can't decode these on-device. Surface
        // the filename instead of silently dropping it.
        return (
          part: {
            'type': 'text',
            'text': '[Archive file: $name]\n($ext archive provided — contents '
                'cannot be decoded on-device; infer intent from the filename.)',
          },
          note: null,
        );
      }

      if (entries.isEmpty) {
        // Nothing readable inlined → give the model a listing.
        List<String> listing;
        if (ext == 'zip') {
          listing = [for (final e in ZipDecoder().decodeBytes(bytes))
            if (e.isFile) p.basename(e.name)];
        } else {
          listing = [for (final e in TarDecoder().decodeBytes(bytes))
            if (e.isFile) p.basename(e.name)];
        }
        if (listing.length > maxZipEntries) {
          listing = listing.sublist(0, maxZipEntries);
        }
        return (
          part: {
            'type': 'text',
            'text': '[Archive file: $name]\n'
                'Entry listing: ${listing.isEmpty ? '(empty archive)' : listing.join(', ')}',
          },
          note: null,
        );
      }

      final body = entries
          .map((e) => '[Entry: ${e.$1}]\n${_cap(e.$2)}')
          .join('\n\n');
      return (
        part: {'type': 'text', 'text': '[Archive file: $name]\n${_cap(body)}'},
        note: null,
      );
    } catch (e) {
      return (
        part: null,
        note: '$name could not be read as an archive ($e)',
      );
    }
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
