import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/agora_config.dart';
import '../shared/theme/app_colors.dart';
import '../services/supabase_service.dart';
import 'supabase_signaling_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// [REWRITE 2026-09-02] Agora-powered audio/video calls.
///
/// Why Agora instead of raw WebRTC-over-Supabase-signaling:
///   • Supabase has no media server — the old flow relied on P2P ICE, which
///     fails behind VPN/NAT (this app ships a VPN!) → one-way audio / no connect.
///   • Agora routes media through its own global SDNs: reliable even over VPN,
///     with echo cancellation, jitter buffering and adaptive bitrate built in.
///
/// Signaling (ring / accept / reject / hang-up) still uses the existing
/// `call_signals` Supabase table — that part works fine and is kept.
class CallScreen extends StatefulWidget {
  final String selfId;
  final String peerId;
  final bool isVideo;
  final bool isCaller;

  /// Set when opened from the incoming-call dialog after user answered.
  final bool autoJoin;

  const CallScreen({
    super.key,
    required this.selfId,
    required this.peerId,
    this.isVideo = false,
    this.isCaller = true,
    this.autoJoin = true,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with WidgetsBindingObserver {
  final SupabaseService _supabaseService = SupabaseService();
  late final SupabaseSignalingClient _sig;

  RtcEngine engine = createAgoraRtcEngine();

  String? _channelName;
  bool _joined = false;
  bool _remoteJoined = false;
  int _remoteUid = 0;

  bool _muted = false;
  bool _speakerOn = false;
  bool _cameraFront = false; // Agora camera direction flag (UI state)

  bool _connected = false; // both peers present
  DateTime? _callStartTime;
  Duration _callDuration = Duration.zero;
  Timer? _callDurationTimer;
  bool _didLogCall = false;
  bool _hangupSent = false;
  bool _joinStarted = false;

  // UI states: calling | ringing(callee pre-answer) | active | ended
  late bool _isCalleeWaiting = !widget.isCaller && !widget.autoJoin;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channelName = AgoraConfig.channelFor(widget.selfId, widget.peerId);
    _sig = SupabaseSignalingClient(
        client: Supabase.instance.client,
        selfId: widget.selfId,
        onlyFromId: widget.peerId);
    _init();
  }

  @override
  void didUpdateWidget(covariant CallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Callee answered the in-screen dialog → join Agora now.
    if (widget.autoJoin && !oldWidget.autoJoin && !_joined && !_joinStarted) {
      _joinStarted = true;
      unawaited(_joinChannel());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _callDurationTimer?.cancel();
    unawaited(_cleanup());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Agora keeps media alive in background on Android (mic service type).
  }

  Future<void> _init() async {
    try {
      await _requestPermissions();

      await engine.initialize(RtcEngineContext(appId: AgoraConfig.appId));

      await engine.setChannelProfile(ChannelProfileType.channelProfileCommunication);
      await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);

      if (widget.isVideo) {
        await engine.enableVideo();
        await engine.startPreview();
      } else {
        await engine.enableAudio();
        // Voice-call friendly settings: force speaker by default for audio calls.
        await engine.setEnableSpeakerphone(true);
        _speakerOn = true;
      }

      engine.registerEventHandler(RtcEngineEventHandler(
        onJoinChannelSuccess: (connection, elapsed) {
          if (!mounted) return;
          setState(() => _joined = true);
          if (widget.isCaller) {
            // Tell callee we're in the channel and ringing.
            unawaited(_sig.send(
              toId: widget.peerId,
              type: 'call_offer',
              payload: {'is_video': widget.isVideo, 'channel': _channelName},
            ));
          } else {
            // Callee answering: announce presence so caller sees us join.
            unawaited(_sig.send(
              toId: widget.peerId,
              type: 'accept',
              payload: {'is_video': widget.isVideo, 'channel': _channelName},
            ));
          }
        },
        onUserJoined: (RtcConnection connection, remoteUid, elapsed) {
          if (!mounted) return;
          setState(() {
            _remoteJoined = true;
            _remoteUid = remoteUid;
            _connected = true;
            _callStartTime ??= DateTime.now();
          });
          _startDurationTimer();
        },
        onUserOffline: (RtcConnection connection, remoteUid, reason) {
          if (!mounted) return;
          if (_remoteUid == remoteUid) {
            _endCall(remoteHungUp: true);
          }
        },
        onError: (err, msg) {
          debugPrint('[Agora] error $err $msg');
        },
      ));

      // ── Signaling: hang-up / decline handling (Supabase realtime) ──
      await _sig.connect(onSignal: (m) async {
        final type = (m['type'] ?? '').toString();
        final from = (m['from_id'] ?? '').toString();
        if (from != widget.peerId) return;
        switch (type) {
          case 'hangup':
          case 'decline':
          case 'busy':
            if (mounted) _endCall(remoteHungUp: true, remoteAction: type);
            break;
          case 'offer_channel':
            // Caller joined first; callee's UI already showing — nothing extra.
            break;
        }
      });

      // Join immediately (caller rings; callee joins after tapping Answer).
      if (!widget.isCaller && !widget.autoJoin) {
        // Callee dialog path — wait for answer before joining.
        return;
      }
      await _joinChannel();
    } catch (e) {
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Call init failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _joinChannel() async {
    if (_joined || _joinStarted || _channelName == null) return;
    _joinStarted = true;
    // [FIX 2026-09-03] Fetch a FRESH Agora token (Edge Function / app_settings
    // / default). Previously an empty token was passed, which fails to
    // authenticate against the certificate-enabled Agora project and left
    // callers stuck on "Connecting…". Tokens are minted just-in-time so they
    // never expire mid-call.
    late final String token;
    try {
      token = await AgoraConfig.resolveRtcToken(
        channel: _channelName!,
        uid: widget.selfId.hashCode.toString(),
      );
    } catch (_) {
      token = AgoraConfig.defaultRtcToken;
    }
    await engine.joinChannel(
      token: token,
      channelId: _channelName!,
      uid: 0,
      options: ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileCommunication,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        publishMicrophoneTrack: true,
        publishCameraTrack: widget.isVideo,
        autoSubscribeAudio: true,
        autoSubscribeVideo: widget.isVideo,
        enableAudioRecordingOrPlayout: true,
      ),
    );
  }

  Future<void> _requestPermissions() async {
    final statuses = <Permission>[
      Permission.microphone,
      if (widget.isVideo) Permission.camera,
    ];
    final result = await statuses.request();
    final denied = result.entries.where((e) => !e.value.isGranted).toList();
    if (denied.isNotEmpty) {
      throw Exception('Missing permissions: ${denied.map((e) => e.key).join(', ')}');
    }
  }

  void _startDurationTimer() {
    _callDurationTimer?.cancel();
    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_callStartTime != null && mounted) {
        setState(() => _callDuration = DateTime.now().difference(_callStartTime!));
      }
    });
  }

  Future<void> _toggleMute() async {
    _muted = !_muted;
    await engine.muteLocalAudioStream(_muted);
    if (mounted) setState(() {});
  }

  Future<void> _toggleSpeaker() async {
    _speakerOn = !_speakerOn;
    await engine.setEnableSpeakerphone(_speakerOn);
    if (mounted) setState(() {});
  }

  Future<void> _switchCamera() async {
    if (!widget.isVideo) return;
    await engine.switchCamera();
    if (mounted) setState(() => _cameraFront = !_cameraFront);
  }

  Future<void> _hangup() async {
    if (!_hangupSent) {
      _hangupSent = true;
      try {
        await _sig.send(
          toId: widget.peerId,
          type: 'hangup',
          payload: {'is_video': widget.isVideo},
        );
      } catch (_) {}
    }
    await _endCall(remoteHungUp: false);
  }

  /// Decline without joining (callee only).
  Future<void> _decline() async {
    try {
      await _sig.send(
        toId: widget.peerId,
        type: 'decline',
        payload: {'is_video': widget.isVideo},
      );
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  Future<void> _answer() async {
    setState(() => _isCalleeWaiting = false);
    await _joinChannel();
  }

  bool _ending = false;
  Future<void> _endCall({bool remoteHungUp = false, String? remoteAction}) async {
    if (_ending) return;
    _ending = true;
    _callDurationTimer?.cancel();

    final durationSeconds = _callDuration.inSeconds;
    if (!_didLogCall) {
      _didLogCall = true;
      try {
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
      } catch (_) {}
    }

    if (mounted && (remoteHungUp || remoteAction != null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(remoteAction == 'decline'
              ? 'Call declined'
              : remoteAction == 'busy'
                  ? 'User busy'
                  : 'Call ended'),
        ),
      );
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _cleanup() async {
    try {
      await _sig.close();
    } catch (_) {}
    try {
      await engine.leaveChannel();
    } catch (_) {}
    try {
      await engine.release();
    } catch (_) {}
  }

  String get _peerLabel {
    // Cheap label: peer UUID prefix. Full name resolution isn't worth a
    // network call mid-ring.
    return widget.peerId.substring(0, 8).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hangup();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B141A),
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Remote video (video calls only)
            if (widget.isVideo && _remoteJoined)
              AgoraVideoView(
                controller: VideoViewController.remote(
                  rtcEngine: engine,
                  canvas: VideoCanvas(uid: _remoteUid),
                  connection: RtcConnection(channelId: _channelName ?? ''),
                ),
              ).animate().fadeIn(duration: 300.ms)
            else
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF0F2027), Color(0xFF0B141A)],
                  ),
                ),
              ),

            // Local preview PiP (video calls)
            if (widget.isVideo)
              Positioned(
                right: 16,
                top: MediaQuery.of(context).padding.top + 80,
                width: 110,
                height: 150,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: AgoraVideoView(
                    controller: VideoViewController(
                      rtcEngine: engine,
                      canvas: const VideoCanvas(uid: 0),
                    ),
                  ),
                ),
              ),

            // Avatar + status text when no video connected yet
            if (!widget.isVideo || !_remoteJoined)
              SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 60),
                    CircleAvatar(
                      radius: 52,
                      backgroundColor: Colors.white.withOpacity(0.08),
                      child: Text(
                        _peerLabel[0],
                        style: const TextStyle(fontSize: 40, color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(_peerLabel,
                        style: GoogleFonts.poppins(
                            color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(_statusText,
                        style: GoogleFonts.poppins(color: Colors.white54, fontSize: 14)),
                  ],
                ),
              ),

            // Bottom controls
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: _isCalleeWaiting ? _buildAnswerBar() : _buildControls(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _statusText {
    if (_isCalleeWaiting) return 'Incoming ${widget.isVideo ? 'video' : 'voice'} call…';
    if (_connected) {
      final m = _callDuration.inMinutes;
      final s = _callDuration.inSeconds % 60;
      return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    if (widget.isCaller) return _joined ? 'Ringing…' : 'Connecting…';
    return 'Joining…';
  }

  Widget _buildAnswerBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CtrlButton(icon: Icons.call_end_rounded, label: 'Decline', color: Colors.redAccent, onTap: _decline),
        _CtrlButton(icon: Icons.call_rounded, label: 'Accept', color: Colors.green, onTap: _answer),
      ],
    );
  }

  Widget _buildControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CtrlButton(
          icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: _muted ? 'Unmute' : 'Mute',
          color: _muted ? Colors.orangeAccent : Colors.white24,
          onTap: _toggleMute,
        ),
        // Speaker toggle shown for BOTH audio and video calls so the user can
        // always switch to loudspeaker (previously missing on video calls).
        _CtrlButton(
          icon: _speakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded,
          label: 'Speaker',
          color: _speakerOn ? AppColors.violet : Colors.white24,
          onTap: _toggleSpeaker,
        ),
        if (widget.isVideo)
          _CtrlButton(
            icon: Icons.cached_rounded,
            label: 'Flip',
            color: Colors.white24,
            onTap: _switchCamera,
          ),
        _CtrlButton(
          icon: Icons.call_end_rounded,
          label: 'End',
          color: Colors.redAccent,
          onTap: _hangup,
        ),
      ],
    );
  }
}

class _CtrlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _CtrlButton({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: GoogleFonts.poppins(color: Colors.white60, fontSize: 12)),
      ],
    );
  }
}
