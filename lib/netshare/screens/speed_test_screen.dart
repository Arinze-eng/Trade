import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({super.key});

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  bool _running = false;
  String? _error;

  double? _downloadMbps;
  double? _uploadMbps;
  int? _downloadBytes;
  int? _uploadBytes;
  int? _downloadMs;
  int? _uploadMs;

  String _fmtBytes(int? bytes) {
    if (bytes == null) return '-';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _downloadMbps = null;
      _uploadMbps = null;
      _downloadBytes = null;
      _uploadBytes = null;
      _downloadMs = null;
      _uploadMs = null;
    });

    final client = http.Client();
    try {
      // Cloudflare speedtest endpoints.
      // Download: GET /__down?bytes=N
      // Upload: POST /__up (request body size is measured)
      const downloadBytesTarget = 10 * 1024 * 1024; // 10 MB
      const uploadBytesTarget = 5 * 1024 * 1024; // 5 MB

      final dSw = Stopwatch()..start();
      final dRes = await client.get(
        Uri.parse('https://speed.cloudflare.com/__down?bytes=$downloadBytesTarget'),
        headers: const {
          // avoid caches
          'Cache-Control': 'no-cache',
        },
      );
      dSw.stop();
      if (dRes.statusCode != 200) {
        throw Exception('Download failed (HTTP ${dRes.statusCode})');
      }
      final dBytes = dRes.bodyBytes.length;
      final dMs = max(1, dSw.elapsedMilliseconds);
      final dMbps = (dBytes * 8) / (dMs / 1000) / 1e6;

      // Upload test: send random bytes.
      final rng = Random.secure();
      final payload = Uint8List(uploadBytesTarget);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = rng.nextInt(256);
      }

      final uSw = Stopwatch()..start();
      final uRes = await client.post(
        Uri.parse('https://speed.cloudflare.com/__up'),
        headers: const {
          'Content-Type': 'application/octet-stream',
          'Cache-Control': 'no-cache',
        },
        body: payload,
      );
      uSw.stop();
      if (uRes.statusCode != 200) {
        throw Exception('Upload failed (HTTP ${uRes.statusCode})');
      }
      final uBytes = payload.length;
      final uMs = max(1, uSw.elapsedMilliseconds);
      final uMbps = (uBytes * 8) / (uMs / 1000) / 1e6;

      setState(() {
        _downloadMbps = dMbps;
        _uploadMbps = uMbps;
        _downloadBytes = dBytes;
        _uploadBytes = uBytes;
        _downloadMs = dMs;
        _uploadMs = uMs;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      client.close();
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Speed Test')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Standalone internet speed test',
                      style:
                          theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Runs a real download + upload against Cloudflare’s speed test endpoints. '
                      'This test is separate from the tunnel and can be used before connecting.',
                      style: TextStyle(color: Colors.white70, height: 1.35),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _running ? null : _run,
                      icon: _running
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.speed),
                      label: Text(_running ? 'Testing…' : 'Run Speed Test'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              )
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Results',
                        style:
                            theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      _row(
                        'Download',
                        _downloadMbps == null ? '-' : '${_downloadMbps!.toStringAsFixed(1)} Mbps',
                      ),
                      _row(
                        'Upload',
                        _uploadMbps == null ? '-' : '${_uploadMbps!.toStringAsFixed(1)} Mbps',
                      ),
                      const Divider(height: 18),
                      _row('Download sample', _fmtBytes(_downloadBytes)),
                      _row('Download time', _downloadMs == null ? '-' : '$_downloadMs ms'),
                      _row('Upload sample', _fmtBytes(_uploadBytes)),
                      _row('Upload time', _uploadMs == null ? '-' : '$_uploadMs ms'),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(k, style: const TextStyle(color: Colors.white70))),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
