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
/// Transport (verified live): GET
///   https://minis-yzdb.onrender.com/v1/chat/completions?token=<TOKEN>&payload=<json>
///   where <json> is {"model":"powerx-agent","messages":[...]}.
///
/// [FIX 2026-09-04] The endpoint ONLY answers GET with the payload in the
/// query string. A POST with the JSON in the body returns HTTP 502 (this was
/// the cause of in-app "error 502" when asking questions). That 2026-09-03 fix
/// went the wrong direction; we reverted to the GET transport that is proven
/// to work by the reference query_powerx.py helper.
///
/// Multimodal file support uses the content-part format:
///   {"role":"user","content":[
///      {"type":"text","text":"What is in this image?"},
///      {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}
///
/// Supported attachments: images (jpg/png/webp/gif/bmp — small only), PDF
/// (text-extracted), plain-text, and ZIP/TAR archives (readable entries
/// inlined + listing).
///
/// The API token AND the base URL can be overridden by the admin from the
/// Admin Panel; both are stored in the Supabase `app_settings` table under
/// keys `netchat_ai_token` and `netchat_ai_base_url` respectively.
class NetchatAiService {
  NetchatAiService._();

  // [FIX 2026-09-04] Default base URL can now be overridden by the admin from
  // the Admin Panel; it is stored in Supabase `app_settings` under key
  // `netchat_ai_base_url`. Falls back to this compiled default.
  static const String defaultBaseUrl =
      'https://minis-yzdb.onrender.com/v1/chat/completions';
  // [UPDATE 2026-09-04] Active PowerX token (rotated by owner).
  static const String defaultToken =
      'px_gOKpn4ukIFjWclQ3xqURY0Frrp6WVSMhiqLAPfhD';
  static const String model = 'powerx-agent';
  static const String settingsTokenKey = 'netchat_ai_token';
  static const String settingsBaseUrlKey = 'netchat_ai_base_url';

  static String? _cachedToken;
  static DateTime? _cachedAt;
  static String? _cachedBaseUrl;
  static DateTime? _cachedBaseUrlAt;

  /// Invalidate the in-memory config caches (called after admin saves a new
  /// token or base URL).
  static void invalidateCache() {
    _cachedToken = null;
    _cachedAt = null;
    _cachedBaseUrl = null;
    _cachedBaseUrlAt = null;
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
          .eq('key', settingsTokenKey)
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

  /// Resolve the active base URL: app_settings override > built-in default.
  /// [NEW 2026-09-04] Allows the admin to point Netchat AI at a different
  /// PowerX endpoint without shipping a new build.
  static Future<String> resolveBaseUrl() async {
    if (_cachedBaseUrl != null &&
        _cachedBaseUrlAt != null &&
        DateTime.now().difference(_cachedBaseUrlAt!) <
            const Duration(minutes: 10)) {
      return _cachedBaseUrl!;
    }
    String url = defaultBaseUrl;
    try {
      final row = await Supabase.instance.client
          .from('app_settings')
          .select('value')
          .eq('key', settingsBaseUrlKey)
          .maybeSingle();
      if (row != null) {
        var v = row['value'];
        if (v is Map) v = v.toString();
        final s = (v ?? '').toString().replaceAll(RegExp(r'^"|"$'), '').trim();
        if (s.isNotEmpty) url = s;
      }
    } catch (_) {
      // fall back to default
    }
    _cachedBaseUrl = url;
    _cachedBaseUrlAt = DateTime.now();
    return url;
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
          {'key': settingsTokenKey, 'value': val},
          onConflict: 'key',
        )
        .select('key');
    if ((res as List).isEmpty) {
      throw Exception('Failed to write Netchat AI token.');
    }
    invalidateCache();
  }

  /// Admin: persist a new base URL into app_settings (INSERT-ON-CONFLICT).
  /// [NEW 2026-09-04] Mirrors the token flow so the admin can switch the AI
  /// endpoint at runtime.
  static Future<void> setAdminBaseUrl(String url) async {
    final trimmed = url.trim();
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      throw Exception('Base URL must start with http:// or https://');
    }
    final val = jsonEncode(trimmed);
    final res = await Supabase.instance.client
        .from('app_settings')
        .upsert(
          {'key': settingsBaseUrlKey, 'value': val},
          onConflict: 'key',
        )
        .select('key');
    if ((res as List).isEmpty) {
      throw Exception('Failed to write Netchat AI base URL.');
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
      // Normalise plain-string history content into content-part arrays so the
      // payload is always uniform (the PowerX model rejects mixed formats).
      Object hContent = m['content'];
      if (hContent is String) {
        hContent = [{'type': 'text', 'text': hContent}];
      }
      messages.add({
        'role': m['role'],
        'content': hContent,
      });
    }
    final content = <Map<String, dynamic>>[
      if (includeUserTextInContent || userText.isNotEmpty)
        {'type': 'text', 'text': userText.isEmpty ? 'Analyse the attached file(s).' : userText},
      ...extraContentParts,
    ];
    messages.add({
      'role': 'user',
      // Always send content as a content-part array — this exactly matches
      // the verified-working reference helper and avoids any plain-string
      // ambiguity with the API.
      'content': content,
    });

    final payload = jsonEncode({'model': model, 'messages': messages});

    final baseUrl = await resolveBaseUrl();
    // [FIX 2026-09-04] The PowerX endpoint ONLY answers GET requests with the
    // payload carried in the query string (?token=...&payload=<json>). Sending
    // the JSON as a POST body returns HTTP 502 (verified live — this was the
    // cause of "Netchat AI ... returned error 502").
    //
    // The previous fix (2026-09-03) had switched to POST-with-body, which broke
    // every request. We now match the transport of the working reference
    // helper (query_powerx.py): GET with token + payload as query params.
    final query = Uri(queryParameters: {
      'token': token,
      'payload': payload,
    });

    final uri = Uri.parse(baseUrl).replace(query: query.query);

    late http.Response resp;
    try {
      resp = await http
          .get(uri,
              headers: {
                'Accept': 'application/json',
                'User-Agent': 'PowerX-NetchatAgent/1.0',
              })
          .timeout(timeout);
    } on SocketException {
      rethrow;
    } on TimeoutException {
      throw Exception('Netchat AI timed out — the server may be sleeping. Try again in a few seconds.');
    }

    if (resp.statusCode != 200) {
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode == 502 ||
          body.contains('upstream unavailable')) {
        throw Exception('AI upstream is busy or waking up — retry in ~20 seconds.');
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
  // The PowerX endpoint (behind Cloudflare) only accepts the payload as a GET
  // query string: ?token=...&payload=<json>. Rows of inline base64 are limited
  // — the provider returns 502 past ~20KB of inline base64 and Cloudflare
  // returns 414 Request-URI Too Large past ~100KB. To keep uploads reliable we
  // cap each raw image/attachment so the encoded URL stays well inside the
  // safe zone; anything bigger gets a clear skip note instead of a 502.
  static const maxImageBytes = 8 * 1024; // 8 KB raw → ~11 KB base64
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
            notes.add('$name skipped (image too large — the AI endpoint '
                'accepts only very small images inline).');
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
