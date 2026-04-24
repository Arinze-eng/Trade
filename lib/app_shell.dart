import 'package:anywherelan/drawer.dart';
import 'package:anywherelan/netshare/widgets/app_background.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

enum AppSection { overview, settings, blockedPeers, diagnostics }

const _supportWhatsAppUrl = 'https://wa.me/2349048554985';

class AppShell extends StatefulWidget {
  final AppSection? selected;
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;

  const AppShell({
    super.key,
    required this.selected,
    required this.body,
    this.appBar,
    this.floatingActionButton,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  Offset? _whatsAppOffset;

  static const _fabSize = 56.0;
  static const _fabMargin = 16.0;

  Offset _defaultOffsetFor(Size size) {
    // Default: bottom-right, above system insets.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final dx = size.width - _fabSize - _fabMargin;
    final dy = size.height - _fabSize - _fabMargin - bottomInset;
    return Offset(dx.clamp(0, dx), dy.clamp(0, dy));
  }

  Offset _clampOffset(Offset raw, Size size) {
    final maxX = (size.width - _fabSize - _fabMargin).clamp(0.0, double.infinity);
    final maxY = (size.height - _fabSize - _fabMargin).clamp(0.0, double.infinity);
    return Offset(
      raw.dx.clamp(_fabMargin, maxX),
      raw.dy.clamp(_fabMargin, maxY),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final hasPermanentDrawer = constraints.maxWidth > 1100;

        final content = SafeArea(
          bottom: false,
          child: hasPermanentDrawer
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MyDrawer(selected: widget.selected, isRetractable: false),
                    Expanded(child: widget.body),
                  ],
                )
              : widget.body,
        );

        final bodySize = Size(constraints.maxWidth, constraints.maxHeight);
        final effectiveOffset = _whatsAppOffset ?? _defaultOffsetFor(bodySize);

        return AppBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: widget.appBar,
            drawer: hasPermanentDrawer ? null : MyDrawer(selected: widget.selected),
            floatingActionButton: widget.floatingActionButton,
            body: Stack(
              children: [
                content,
                Positioned(
                  left: _clampOffset(effectiveOffset, bodySize).dx,
                  top: _clampOffset(effectiveOffset, bodySize).dy,
                  child: _DraggableWhatsAppButton(
                    onMove: (delta) {
                      setState(() {
                        final next = effectiveOffset + delta;
                        _whatsAppOffset = _clampOffset(next, bodySize);
                      });
                    },
                    onTap: () async {
                      await launchUrlString(_supportWhatsAppUrl);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DraggableWhatsAppButton extends StatelessWidget {
  final void Function(Offset delta) onMove;
  final VoidCallback onTap;

  const _DraggableWhatsAppButton({required this.onMove, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onPanUpdate: (details) => onMove(details.delta),
        onTap: onTap,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: const Color(0xFF25D366),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(Icons.chat, color: Colors.white),
        ),
      ),
    );
  }
}
