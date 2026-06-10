import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/supabase_service.dart';
import '../shared/theme/app_colors.dart';

/// A WhatsApp-style call history list. Reads from the `call_history` table
/// (already populated by `logMissedCall` in supabase_service).
///
/// We display rows showing: peer, type (audio/video), status (missed / answered
/// / outgoing), and a relative timestamp. Tapping triggers a callback to start
/// a new call (handled by the parent if wired) — for now just shows a snackbar.
class CallsHistoryScreen extends StatefulWidget {
  const CallsHistoryScreen({super.key});

  @override
  State<CallsHistoryScreen> createState() => _CallsHistoryScreenState();
}

class _CallsHistoryScreenState extends State<CallsHistoryScreen> {
  final _client = Supabase.instance.client;
  final _supabaseService = SupabaseService();

  List<Map<String, dynamic>> _calls = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = _supabaseService.currentUser;
      if (user == null) {
        setState(() {
          _loading = false;
          _calls = [];
        });
        return;
      }
      final res = await _client
          .from('call_history')
          .select()
          .or('caller_id.eq.${user.id},receiver_id.eq.${user.id}')
          .order('started_at', ascending: false)
          .limit(200);
      final list =
          (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

      // Hydrate peer profiles in batch
      final peerIds = <String>{};
      for (final c in list) {
        final cid = (c['caller_id'] ?? '').toString();
        final rid = (c['receiver_id'] ?? '').toString();
        final peer = cid == user.id ? rid : cid;
        if (peer.isNotEmpty) peerIds.add(peer);
      }
      final profiles = <String, Map<String, dynamic>>{};
      if (peerIds.isNotEmpty) {
        final profRes = await _client
            .from('profiles')
            .select('id, username, display_name, email')
            .inFilter('id', peerIds.toList());
        for (final p
            in (profRes as List).map((e) => Map<String, dynamic>.from(e as Map))) {
          profiles[(p['id'] ?? '').toString()] = p;
        }
      }
      for (final c in list) {
        final cid = (c['caller_id'] ?? '').toString();
        final rid = (c['receiver_id'] ?? '').toString();
        final peer = cid == user.id ? rid : cid;
        c['_peer'] = profiles[peer];
        c['_outgoing'] = cid == user.id;
      }

      if (!mounted) return;
      setState(() {
        _calls = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  String _relTime(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0B141A) : AppColors.lightScaffoldBg;
    final textColor = isDark ? Colors.white : Colors.black87;
    final dividerColor = isDark ? Colors.white.withOpacity(0.06) : Colors.grey.shade200;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Calls',
            style: GoogleFonts.sora(fontWeight: FontWeight.w800, color: textColor)),
        flexibleSpace: isDark
            ? Container(
                decoration: const BoxDecoration(gradient: AppColors.accentGradient),
                child: Container(color: Colors.black.withOpacity(0.55)),
              )
            : null,
        iconTheme: IconThemeData(color: textColor),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: textColor),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _calls.isEmpty
                  ? _buildEmpty()
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                        cacheExtent: 500,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: _calls.length,
                        separatorBuilder: (_, __) =>
                            Divider(color: dividerColor, height: 1),
                        itemBuilder: (context, i) => RepaintBoundary(child: _row(_calls[i])),
                      ),
                    ),
    );
  }

  Widget _buildEmpty() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = isDark ? Colors.white24 : Colors.grey.shade300;
    final titleColor = isDark ? Colors.white70 : Colors.grey.shade600;
    final subColor = isDark ? Colors.white38 : Colors.grey.shade500;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.call_rounded, color: iconColor, size: 56),
          const SizedBox(height: 14),
          Text('No calls yet',
              style: GoogleFonts.poppins(
                  color: titleColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 16)),
          const SizedBox(height: 6),
          Text('Voice and video calls will appear here',
              style: GoogleFonts.poppins(color: subColor, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildError() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white70 : Colors.grey.shade600;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Text(_error ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(color: textColor)),
            const SizedBox(height: 14),
            ElevatedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> c) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final peer = (c['_peer'] as Map<String, dynamic>?) ?? const {};
    final outgoing = c['_outgoing'] == true;
    final status = (c['status'] ?? '').toString();
    final isVideo = (c['call_type'] ?? '').toString() == 'video';
    final missed = status == 'missed' && !outgoing;

    final name = (peer['display_name'] ?? '').toString().trim().isNotEmpty
        ? peer['display_name'].toString()
        : (peer['username'] ?? 'Unknown').toString();
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    final titleColor = missed ? Colors.redAccent : (isDark ? Colors.white : Colors.black87);
    final subtitleColor = isDark ? Colors.white60 : Colors.grey.shade600;

    final iconArrow = outgoing
        ? Icons.call_made_rounded
        : (missed ? Icons.call_missed_rounded : Icons.call_received_rounded);
    final arrowColor =
        missed ? Colors.redAccent : (outgoing ? Colors.greenAccent : Colors.tealAccent);

    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: AppColors.violet,
        child: Text(initial,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      title: Text(name,
          style: GoogleFonts.poppins(
              color: titleColor,
              fontWeight: FontWeight.w600)),
      subtitle: Row(
        children: [
          Icon(iconArrow, size: 14, color: arrowColor),
          const SizedBox(width: 4),
          Text(
            '${outgoing ? 'Outgoing' : (missed ? 'Missed' : 'Incoming')} '
            '· ${_relTime(c['started_at']?.toString())}',
            style: GoogleFonts.poppins(color: subtitleColor, fontSize: 12),
          ),
        ],
      ),
      trailing: Icon(
        isVideo ? Icons.videocam_rounded : Icons.call_rounded,
        color: AppColors.violet,
      ),
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Open chat with $name to call back',
                  style: GoogleFonts.poppins())),
        );
      },
    );
  }
}
