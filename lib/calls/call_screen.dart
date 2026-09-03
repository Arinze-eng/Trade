import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zego_express_engine/zego_express_engine.dart';

import '../services/supabase_service.dart';
import '../services/zego_config.dart';
import '../shared/theme/app_colors.dart';
import 'supabase_signaling_client.dart';

/// [REWRITE 2026-09-03] ZegoCloud Express-powered audio/video calls.
///
/// Replaces the previous Agora integration. Why ZegoCloud:
///   • ZegoCloud routes media through its own global SDNs — reliable even over
///     VPN/NAT (this app ships a VPN!). Same architecture class as Agora.
///   • Much simpler auth: uses appID + AppSign directly, NO per-call token
///     minting (no agora-token Edge Function, no expiring token problems).
///   • AppID/AppSign are admin-editable via `app_settings`.
///
/// Signaling (ring / accept / reject / hang-up) still uses the existing
/// `call_signals` Supabase table — that flow is unchanged and kept.
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

  ZegoExpressEngine get engine => ZegoExpressEngine.instance;

  String? _roomID;
  String? _publishStreamID; // local publisher stream
  String? _remoteStreamID; // remote peer stream

  // Canvas views (platform views for rendering)
  int? _localViewID;
  int? _remoteViewID;
  Widget? _localVideoView;
  Widget? _remoteVideoView;

  bool _roomJoined = false;
  bool _remoteJoined = false;

  bool _muted = false;
  bool _speakerOn = false;
  bool _cameraFront = true; // true = front camera

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
    _roomID = ZegoConfig.roomFor(widget.selfId, widget.peerId);
    _sig = SupabaseSignalingClient(
        client: Supabase.instance.client,
        selfId: widget.selfId,
        onlyFromId: widget.peerId);
    _init();
  }

  @override
  void didUpdateWidget(covariant CallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Callee answered the in-screen dialog → join Zego now.
    if (widget.autoJoin && !oldWidget.autoJoin && !_roomJoined && !_joinStarted) {
      _joinStarted = true;
      unawaited(_joinRoom());
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
    // Zego keeps media alive in background on Android (mic service type).
  }

  /// Create engine + prepare canvas views + wire events, then join.
  Future<void> _init() async {
    try {
      await _requestPermissions();

      // Load admin-overridable credentials.
      final cfg = await ZegoConfig.resolveConfig();

      // Create / re-create the engine (SDK requires one instance at a time).
      await ZegoExpressEngine.createEngineWithProfile(
        ZegoEngineProfile(
          cfg.appId,
          ZegoScenario.Default,
          appSign: cfg.appSign,
        ),
      );

      // Local preview canvas.
      if (widget.isVideo) {
        int? tmpViewID;
        final viewWidget = await engine.createCanvasView((viewID) {
          tmpViewID = viewID;
          if (mounted) {
            setState(() => _localViewID = viewID);
          }
          unawaited(_startLocalPreview(viewID));
        });
        if (mounted) {
          setState(() {
            _localVideoView = viewWidget;
            if (tmpViewID != null) _localViewID = tmpViewID;
          });
        }
      }

      // ── Event handlers (static callbacks on ZegoExpressEngine) ──
      // Room state (join success/failure/disconnect).
      ZegoExpressEngine.onRoomStateUpdate =
          (roomID, state, errorCode, extendedData) {
        if (!mounted) return;
        if (errorCode != 0) {
          debugPrint('[Zego] room state error: $errorCode, $extendedData');
        }
        if (state == ZegoRoomState.Connected) {
          setState(() => _roomJoined = true);
        }
      };

      // Remote user joined/left the room → drives connect/end states.
      ZegoExpressEngine.onRoomUserUpdate =
          (roomID, updateType, userList) {
        if (!mounted) return;
        for (final u in userList) {
          if (u.userID == widget.peerId) {
            if (updateType == ZegoUpdateType.Add) {
              // Peer is in the room → start playing their stream.
              setState(() {
                _remoteJoined = true;
                _connected = true;
                _callStartTime ??= DateTime.now();
              });
              _startDurationTimer();
              unawaited(_startPlayingRemote());
            } else if (updateType == ZegoUpdateType.Delete) {
              _endCall(remoteHungUp: true);
            }
          }
        }
      };

      // Remote stream became available / playback ended.
      ZegoExpressEngine.onRoomStreamUpdate =
          (roomID, updateType, streamList, extendedData) {
        if (!mounted) return;
        for (final s in streamList) {
          if (s.user.userID == widget.peerId) {
            if (updateType == ZegoUpdateType.Add && _remoteStreamID == null) {
              _remoteStreamID = s.streamID;
              if (_remoteJoined) unawaited(_startPlayingRemote());
            } else if (updateType == ZegoUpdateType.Delete) {
              _endCall(remoteHungUp: true);
            }
          }
        }
      };

      // Playback state changes.
      ZegoExpressEngine.onPlayerStateUpdate =
          (streamID, state, errorCode, extendedData) {
        if (!mounted) return;
        if (errorCode != 0) {
          debugPrint('[Zego] player error $errorCode for $streamID');
        }
        if (state == ZegoPlayerState.Playing) {
          setState(() {
            _remoteJoined = true;
            _connected = true;
            _callStartTime ??= DateTime.now();
          });
          _startDurationTimer();
        }
      };

      // Publish state changes (diagnostics).
      ZegoExpressEngine.onPublisherStateUpdate =
          (streamID, state, errorCode, extendedData) {
        if (errorCode != 0) {
          debugPrint('[Zego] publish error $errorCode for $streamID');
        }
      };

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

      // For audio-only calls, force speakerphone on by default.
      if (!widget.isVideo) {
        await engine.setAudioRouteToSpeaker(true);
        _speakerOn = true;
      }

      // Join immediately (caller rings; callee joins after tapping Answer).
      if (!widget.isCaller && !widget.autoJoin) {
        // Callee dialog path — wait for answer before joining.
        return;
      }
      await _joinRoom();
    } catch (e) {
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Call init failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _startLocalPreview(int viewID) async {
    try {
      await engine.startPreview(canvas: ZegoCanvas.view(viewID));
    } catch (_) {}
  }

  Future<void> _joinRoom() async {
    if (_roomJoined || _joinStarted || _roomID == null) return;
    _joinStarted = true;

    final user = ZegoConfig.localUser(widget.selfId);
    final res = await engine.loginRoom(
      _roomID!,
      user,
      config: ZegoRoomConfig(
        0, // maxMemberCount (0 = unlimited)
        true, // isUserStatusNotify → receive onRoomUserUpdate
        '', // token (not needed in basic appID+AppSign mode)
      ),
    );
    if (res.errorCode != 0) {
      debugPrint('[Zego] loginRoom error: ${res.errorCode} ${res.extendedData}');
    } else {
      setState(() => _roomJoined = true);
    }

    // Setup local publish.
    _publishStreamID = ZegoConfig.streamIdFor(_roomID!, widget.selfId);
    if (widget.isVideo) {
      await engine.enableCamera(true);
      if (_localViewID != null) {
        await _startLocalPreview(_localViewID!);
      }
    } else {
      await engine.enableCamera(false);
    }
    await engine.muteMicrophone(false);
    await engine.startPublishingStream(_publishStreamID!);

    // Signal the peer.
    if (widget.isCaller) {
      unawaited(_sig.send(
        toId: widget.peerId,
        type: 'call_offer',
        payload: {'is_video': widget.isVideo, 'channel': _roomID},
      ));
    } else {
      // Callee answering: announce presence so caller sees us.
      unawaited(_sig.send(
        toId: widget.peerId,
        type: 'accept',
        payload: {'is_video': widget.isVideo, 'channel': _roomID},
      ));
    }
  }

  Future<void> _startPlayingRemote() async {
    final streamID = _remoteStreamID;
    if (streamID == null || !mounted) return;
    if (_remoteViewID == null && widget.isVideo) {
      await engine.createCanvasView((viewID) {
        if (!mounted) return;
        setState(() => _remoteViewID = viewID);
        unawaited(engine.startPlayingStream(
          streamID,
          canvas: ZegoCanvas.view(viewID),
        ));
      }).then((widget) {
        if (mounted) setState(() => _remoteVideoView = widget);
      });
    } else {
      await engine.startPlayingStream(
        streamID,
        canvas: widget.isVideo && _remoteViewID != null
            ? ZegoCanvas.view(_remoteViewID!)
            : null,
      );
    }
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
    await engine.muteMicrophone(_muted);
    if (mounted) setState(() {});
  }

  Future<void> _toggleSpeaker() async {
    _speakerOn = !_speakerOn;
    if (_speakerOn) {
      await engine.setAudioRouteToSpeaker(true);
    } else {
      // route back to earpiece
      await engine.setAudioRouteToSpeaker(false);
    }
    if (mounted) setState(() {});
  }

  Future<void> _switchCamera() async {
    if (!widget.isVideo) return;
    _cameraFront = !_cameraFront;
    await engine.useFrontCamera(_cameraFront);
    if (mounted) setState(() {});
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
    await _joinRoom();
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
      if (_publishStreamID != null) {
        await engine.stopPublishingStream();
      }
    } catch (_) {}
    try {
      if (_remoteStreamID != null) {
        await engine.stopPlayingStream(_remoteStreamID!);
      }
    } catch (_) {}
    try {
      if (_roomID != null) {
        await engine.logoutRoom();
      }
    } catch (_) {}
    try {
      if (_localViewID != null) {
        await engine.destroyCanvasView(_localViewID!);
      }
      if (_remoteViewID != null) {
        await engine.destroyCanvasView(_remoteViewID!);
      }
    } catch (_) {}
    try {
      await ZegoExpressEngine.destroyEngine();
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
            if (widget.isVideo && _remoteJoined && _remoteVideoView != null)
              SizedBox.expand(child: _remoteVideoView!).animate().fadeIn(duration: 300.ms)
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
            if (widget.isVideo && _localVideoView != null)
              Positioned(
                right: 16,
                top: MediaQuery.of(context).padding.top + 80,
                width: 110,
                height: 150,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: _localVideoView!,
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
    if (widget.isCaller) return _roomJoined ? 'Ringing…' : 'Connecting…';
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
        // Speaker toggle shown for BOTH audio and video calls.
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