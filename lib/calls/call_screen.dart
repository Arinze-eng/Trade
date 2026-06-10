import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_signaling_client.dart';
import '../services/supabase_service.dart';

/// [UPDATE 2026-06-10] TURN server + phantom call fix + audio stability
///
/// Phantom call fix:
/// - Call signals older than 10 seconds are ignored
/// - Local timeout: ringing state auto-cancels after 20 seconds
/// - Only process signals from the expected peer
///
/// TURN:
/// - Added expressturn.com TURN servers for reliable NAT traversal
/// - Multiple fallback TURN entries (UDP, TCP, TLS)
/// - Kept Google STUN as primary fallback
class CallScreen extends StatefulWidget {
  final String selfId;
  final String peerId;
  final bool isVideo;
  final bool isCaller;

  const CallScreen({
    super.key,
    required this.selfId,
    required this.peerId,
    required this.isVideo,
    this.isCaller = true,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with WidgetsBindingObserver {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();

  MediaStream? _localStream;
  RTCPeerConnection? _pc;
  late final SupabaseSignalingClient _sig;
  final SupabaseService _supabaseService = SupabaseService();

  bool _micOn = true;
  bool _camOn = true;
  bool _speakerOn = true;

  bool _connected = false;
  bool _didLogCall = false;
  DateTime? _callStartTime;
  Timer? _callDurationTimer;
  Duration _callDuration = Duration.zero;

  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  // Phantom call prevention: track ringing start time
  DateTime? _ringingStartedAt;
  Timer? _ringingTimeoutTimer;
  static const Duration _ringingTimeout = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _speakerOn = widget.isVideo; // Set speaker based on call type
    _sig = SupabaseSignalingClient(client: Supabase.instance.client, selfId: widget.selfId);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _connected) {
      // Keep call running
    }
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    try {
      await _configureAudioSession();
    } catch (_) {}

    await _sig.connect(onSignal: (m) async {
      final fromId = (m['from_id'] ?? '').toString();
      if (fromId.isEmpty || fromId != widget.peerId) return;

      // ── PHANTOM CALL FIX: Only process signals < 10 seconds old ──
      final createdAtStr = (m['created_at'] ?? '').toString();
      final createdAt = DateTime.tryParse(createdAtStr);
      if (createdAt != null) {
        final age = DateTime.now().toUtc().difference(createdAt.toUtc());
        if (age.inSeconds > 10) {
          debugPrint('CallScreen: ignoring stale signal (${age.inSeconds}s old)');
          return;
        }
      }

      final type = (m['type'] ?? '').toString();
      final payload = Map<String, dynamic>.from(m['payload'] as Map);

      if (type == 'offer' || type == 'call_offer') {
        if (type == 'call_offer') return;

        // Start ringing timeout
        _startRingingTimeout();

        await _ensurePeerConnection();
        await _pc!.setRemoteDescription(RTCSessionDescription(payload['sdp'] as String?, 'offer'));
        _remoteDescriptionSet = true;
        await _flushPendingCandidates();

        final ans = await _pc!.createAnswer();
        await _pc!.setLocalDescription(ans);
        await _sig.send(
          toId: widget.peerId,
          type: 'answer',
          payload: {'sdp': ans.sdp},
        );
      }

      if (type == 'answer') {
        await _ensurePeerConnection();
        await _pc?.setRemoteDescription(RTCSessionDescription(payload['sdp'] as String?, 'answer'));
        _remoteDescriptionSet = true;
        await _flushPendingCandidates();
        _onCallConnected();
      }

      if (type == 'ice') {
        final c = Map<String, dynamic>.from(payload['candidate'] as Map);
        final candidate = RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']);

        if (_remoteDescriptionSet) {
          await _pc?.addCandidate(candidate);
        } else {
          _pendingCandidates.add(candidate);
        }
      }

      if (type == 'hangup') {
        _onRemoteHangup();
      }
    });

    if (widget.isCaller) {
      await _startAsCaller();
      _startRingingTimeout();
    }
  }

  /// Phantom call fix: auto-cancel ringing after 20 seconds
  void _startRingingTimeout() {
    _ringingStartedAt ??= DateTime.now();
    _ringingTimeoutTimer?.cancel();
    _ringingTimeoutTimer = Timer(_ringingTimeout, () {
      if (!_connected && mounted) {
        debugPrint('CallScreen: ringing timeout - auto cancelling');
        _logAndPop();
      }
    });
  }

  Future<void> _configureAudioSession() async {
    try {
      await Helper.ensureAudioSession();
    } catch (_) {}

    try {
      await Helper.setSpeakerphoneOn(_speakerOn);
    } catch (_) {}
  }

  Future<void> _flushPendingCandidates() async {
    for (final c in _pendingCandidates) {
      await _pc?.addCandidate(c);
    }
    _pendingCandidates.clear();
  }

  void _onCallConnected() {
    if (_connected) return;
    setState(() => _connected = true);

    // Cancel ringing timeout since call connected
    _ringingTimeoutTimer?.cancel();

    _callStartTime = DateTime.now();
    _reapplyAudioConfig();

    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_callStartTime != null && mounted) {
        setState(() {
          _callDuration = DateTime.now().difference(_callStartTime!);
        });
      }
    });
  }

  Future<void> _reapplyAudioConfig() async {
    try {
      if (_localStream != null) {
        for (final track in _localStream!.getAudioTracks()) {
          track.enabled = true;
          try {
            await Helper.setMicrophoneMute(false, track);
          } catch (_) {}
        }
      }
      try {
        await Helper.setSpeakerphoneOn(_speakerOn);
      } catch (_) {}
    } catch (_) {}
  }

  void _onRemoteHangup() {
    if (!mounted) return;
    _logAndPop();
  }

  Future<void> _ensurePeerConnection() async {
    if (_pc != null) return;

    final config = {
      'sdpSemantics': 'unified-plan',
      'iceServers': [
        // Google STUN servers
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun2.l.google.com:19302'},
        {'urls': 'stun:stun3.l.google.com:19302'},
        {'urls': 'stun:stun4.l.google.com:19302'},

        // ── [UPDATE 2026-06-10] TURN server for reliable calls ──
        // These relay media when P2P fails (symmetric NATs, firewalls)
        // free.expressturn.com
        {
          'urls': 'turn:free.expressturn.com:3478',
          'username': '000000002094301083',
          'credential': 'Uz10c+zqsHQgQYKs1zGs2A+/09M=',
        },
        // TURN over TCP fallback
        {
          'urls': 'turn:free.expressturn.com:3478?transport=tcp',
          'username': '000000002094301083',
          'credential': 'Uz10c+zqsHQgQYKs1zGs2A+/09M=',
        },
        // TURN TLS (secure, works through most firewalls)
        {
          'urls': 'turns:free.expressturn.com:443',
          'username': '000000002094301083',
          'credential': 'Uz10c+zqsHQgQYKs1zGs2A+/09M=',
        },
        // Metered TURN as additional backup
        {
          'urls': 'turn:a.relay.metered.ca:80',
          'username': 'e8dd65b92f7b828b1d79c8e0',
          'credential': 'fRjpnOLv0/lXMBvd',
        },
        {
          'urls': 'turn:a.relay.metered.ca:443',
          'username': 'e8dd65b92f7b828b1d79c8e0',
          'credential': 'fRjpnOLv0/lXMBvd',
        },
        {
          'urls': 'turn:a.relay.metered.ca:443?transport=tcp',
          'username': 'e8dd65b92f7b828b1d79c8e0',
          'credential': 'fRjpnOLv0/lXMBvd',
        },
      ],
    };

    _pc = await createPeerConnection(config);

    _pc!.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _sig.send(
        toId: widget.peerId,
        type: 'ice',
        payload: {
          'candidate': {
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          }
        },
      );
    };

    _pc!.onTrack = (e) {
      if (e.streams.isNotEmpty) {
        _remoteRenderer.srcObject = e.streams.first;
        _onCallConnected();
        setState(() {});
      }
    };

    _pc!.onAddStream = (stream) {
      _remoteRenderer.srcObject = stream;
      _onCallConnected();
      if (mounted) setState(() {});
    };

    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _onCallConnected();
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        if (mounted) _logAndPop();
      }
    };

    _localStream ??= await navigator.mediaDevices.getUserMedia({
      'audio': {
        'mandatory': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'optional': [
          {'googEchoCancellation': true},
          {'googNoiseSuppression': true},
          {'googAutoGainControl': true},
          {'googHighpassFilter': true},
          {'googTypingNoiseDetection': true},
        ],
      },
      'video': widget.isVideo
          ? {
              'mandatory': {
                'minWidth': '640',
                'minHeight': '480',
                'minFrameRate': '30',
              },
              'optional': [],
            }
          : false,
    });

    // Ensure audio track is enabled
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = true;
      try {
        await Helper.setMicrophoneMute(false, track);
      } catch (_) {}
    }

    for (final t in _localStream!.getTracks()) {
      await _pc!.addTrack(t, _localStream!);
    }

    if (widget.isVideo) {
      _localRenderer.srcObject = _localStream;
    }

    setState(() {});
  }

  Future<void> _startAsCaller() async {
    await _ensurePeerConnection();
    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': widget.isVideo,
    });
    await _pc!.setLocalDescription(offer);
    await _sig.send(
      toId: widget.peerId,
      type: 'offer',
      payload: {'sdp': offer.sdp},
    );
  }

  Future<void> _hangUp() async {
    try {
      await _sig.send(
        toId: widget.peerId,
        type: 'hangup',
        payload: {'reason': 'user_hangup'},
      );
    } catch (_) {}

    _logAndPop();
  }

  void _logAndPop() async {
    if (_didLogCall) {
      _ringingTimeoutTimer?.cancel();
      _callDurationTimer?.cancel();
      await _sig.close();
      await _pc?.close();
      _pc = null;
      await _localStream?.dispose();
      _localStream = null;
      await _localRenderer.dispose();
      await _remoteRenderer.dispose();
      if (mounted) Navigator.pop(context);
      return;
    }
    _didLogCall = true;

    _ringingTimeoutTimer?.cancel();
    _callDurationTimer?.cancel();

    final durationSeconds = _callDuration.inSeconds;

    if (durationSeconds > 0) {
      await _supabaseService.logCompletedCall(
        callerId: widget.selfId,
        receiverId: widget.peerId,
        isVideo: widget.isVideo,
        durationSeconds: durationSeconds,
      );
    } else if (widget.isCaller) {
      await _supabaseService.logMissedCall(
        callerId: widget.selfId,
        receiverId: widget.peerId,
        isVideo: widget.isVideo,
      );
    }

    await _supabaseService.cleanupOldCallSignals();
    await _supabaseService.cleanupExpiredCallSignals();

    await _sig.close();
    await _pc?.close();
    _pc = null;

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        track.stop();
      }
      await _localStream?.dispose();
      _localStream = null;
    }

    try {
      await Helper.setSpeakerphoneOn(true);
    } catch (_) {}

    await _localRenderer.dispose();
    await _remoteRenderer.dispose();

    if (mounted) Navigator.pop(context);
  }

  void _toggleMic() {
    _micOn = !_micOn;
    for (final t in _localStream?.getAudioTracks() ?? const []) {
      t.enabled = _micOn;
    }
    setState(() {});
  }

  void _toggleCam() {
    _camOn = !_camOn;
    for (final t in _localStream?.getVideoTracks() ?? const []) {
      t.enabled = _camOn;
    }
    setState(() {});
  }

  Future<void> _toggleSpeaker() async {
    _speakerOn = !_speakerOn;
    try {
      await Helper.setSpeakerphoneOn(_speakerOn);
    } catch (_) {}
    setState(() {});
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ringingTimeoutTimer?.cancel();
    _callDurationTimer?.cancel();

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        track.stop();
      }
    }

    try {
      Helper.setSpeakerphoneOn(true);
    } catch (_) {}

    unawaited(_sig.close());
    unawaited(_pc?.close());
    unawaited(_localStream?.dispose());
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.isVideo ? 'Video call' : 'Voice call'),
            Text(
              _connected ? _formatDuration(_callDuration) : 'Calling...',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: widget.isVideo
                ? Stack(
                    children: [
                      Positioned.fill(
                        child: RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                      ),
                      Positioned(
                        right: 16,
                        top: 16,
                        width: 120,
                        height: 160,
                        child: DecoratedBox(
                          decoration: BoxDecoration(border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(12)),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: RTCVideoView(_localRenderer, mirror: true),
                          ),
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.call_rounded, color: Colors.white70, size: 86),
                        const SizedBox(height: 20),
                        Text(
                          _connected ? _formatDuration(_callDuration) : 'Calling...',
                          style: const TextStyle(color: Colors.white54, fontSize: 24),
                        ),
                      ],
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    onPressed: _toggleMic,
                    icon: Icon(_micOn ? Icons.mic_rounded : Icons.mic_off_rounded, color: Colors.white),
                  ),
                  if (widget.isVideo)
                    IconButton(
                      onPressed: _toggleCam,
                      icon: Icon(_camOn ? Icons.videocam_rounded : Icons.videocam_off_rounded, color: Colors.white),
                    ),
                  IconButton(
                    onPressed: _toggleSpeaker,
                    icon: Icon(_speakerOn ? Icons.volume_up_rounded : Icons.hearing_disabled_rounded, color: Colors.white),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                    onPressed: _hangUp,
                    child: const Icon(Icons.call_end_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}