import 'package:flutter/material.dart';

class GradientHeader extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const GradientHeader({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(18, 14, 18, 18),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primary.withOpacity(0.14),
            cs.secondary.withOpacity(0.10),
            cs.tertiary.withOpacity(0.08),
          ],
        ),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
      ),
      child: child,
    );
  }
}
