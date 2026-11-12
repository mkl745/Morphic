/// Motion that responds to real state changes, never a fabricated progress timeline.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Fades/rises the current event label. The previous label is removed immediately, so an
/// old engine phase is never presented as current while the next one fades in.
class MorphicStageLabel extends StatelessWidget {
  const MorphicStageLabel({
    super.key,
    required this.stageKey,
    required this.label,
    required this.style,
  });

  final String stageKey;
  final String label;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: AnimatedSwitcher(
          duration: MorphicMotion.standard,
          switchInCurve: MorphicMotion.easing,
          layoutBuilder: (current, previous) => current ?? const SizedBox.shrink(),
          transitionBuilder: (child, animation) => AnimatedBuilder(
            animation: animation,
            child: child,
            builder: (context, child) => Opacity(
              opacity: animation.value,
              child: Transform.translate(
                offset: Offset(0, reduced ? 0 : MorphicMotion.entranceRise * (1 - animation.value)),
                child: child,
              ),
            ),
          ),
          child: Text(label, key: ValueKey(stageKey), style: style),
        ),
      ),
    );
  }
}

/// Uses a single shared 400 ms clock for the *whole* workspace, not one timer per card.
/// Late-built/lazy cards therefore cannot prolong the entrance, and the visual animation
/// never delays the engine, navigation, or a component's data request.
class MorphicEntrance extends StatelessWidget {
  const MorphicEntrance({
    super.key,
    required this.animation,
    required this.index,
    required this.child,
  });

  final Animation<double> animation;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final total = MorphicMotion.entranceLimit.inMilliseconds;
    final duration = MorphicMotion.standard.inMilliseconds;
    final delay = reduced
        ? 0
        : math.min(math.max(index, 0) * MorphicMotion.stagger.inMilliseconds, total - duration);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final elapsed = animation.value * total;
        final progress = ((elapsed - delay) / duration).clamp(0.0, 1.0).toDouble();
        final value = MorphicMotion.easing.transform(progress);
        return IgnorePointer(
          ignoring: value == 0,
          child: Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, reduced ? 0 : MorphicMotion.entranceRise * (1 - value)),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
