import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

/// The animated intro the app opens on.
///
/// Brand mark, name and tagline stagger in, hold, then the whole screen fades
/// out and [onDone] hands over. The sequence is driven by one
/// [AnimationController] and four [Interval]s over it rather than by chained
/// `Future.delayed` calls, so it is deterministic, testable with
/// `pumpAndSettle`, and collapses to a single frame when the platform asks for
/// reduced motion.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.onDone});

  /// Called once the outro finishes, or immediately when motion is reduced.
  final VoidCallback? onDone;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  late final Animation<double> _mark = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.00, 0.35, curve: Curves.elasticOut),
  );
  late final Animation<double> _name = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.20, 0.55, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _tagline = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.45, 0.75, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _cta = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.70, 0.90, curve: Curves.easeOut),
  );
  late final Animation<double> _outro = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.90, 1.00, curve: Curves.easeIn),
  );

  /// Set once [onDone] has fired, so a rebuild cannot call it twice.
  bool _handedOver = false;

  @override
  void initState() {
    super.initState();
    // `MediaQuery` is not readable in `initState`, so reduced motion is
    // resolved on the first frame and the animation is skipped there instead.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _start() {
    if (!mounted) return;
    if (MediaQuery.of(context).disableAnimations) {
      _handedOver = true;
      widget.onDone?.call();
      return;
    }
    _c.forward().whenComplete(() {
      if (!mounted || _handedOver) return;
      _handedOver = true;
      widget.onDone?.call();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MngColors.primary,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            return Opacity(
              opacity: 1 - _outro.value,
              child: Padding(
                padding: EdgeInsets.all(24.w),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _markBadge(),
                    SizedBox(height: 24.h),
                    _fadeUp(
                      _name,
                      Text(
                        "Meet 'N Go",
                        style: MngTheme.light.textTheme.headlineMedium?.copyWith(
                          color: MngColors.onPrimary,
                          fontSize: 40,
                        ),
                      ),
                    ),
                    SizedBox(height: 8.h),
                    _fadeUp(
                      _tagline,
                      Text(
                        'Make a beeline across the city',
                        style: MngTheme.light.textTheme.titleMedium?.copyWith(
                          color: MngColors.onPrimary,
                        ),
                      ),
                    ),
                    SizedBox(height: 32.h),
                    _fadeUp(
                      _cta,
                      Row(
                        children: [
                          const _PulseDot(),
                          SizedBox(width: 10.w),
                          Text(
                            'Getting things moving',
                            style: MngTheme.light.textTheme.bodySmall?.copyWith(
                              color: MngColors.onPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// The mark scales in on an elastic curve so it arrives with a little weight.
  Widget _markBadge() {
    return ScaleTransition(
      scale: _mark,
      child: Container(
        width: 88.w,
        height: 88.w,
        decoration: BoxDecoration(
          color: MngColors.onPrimary,
          borderRadius: BorderRadius.circular(MngRadius.large),
        ),
        child: Icon(
          Icons.directions_car_filled,
          size: 48.w,
          color: MngColors.primary,
        ),
      ),
    );
  }

  Widget _fadeUp(Animation<double> animation, Widget child) {
    return Opacity(
      opacity: animation.value,
      child: Transform.translate(
        offset: Offset(0, 18.h * (1 - animation.value)),
        child: child,
      ),
    );
  }
}

/// A three-dot pulse on the same driver as the rest of the intro, so the whole
/// screen breathes together rather than one element ticking on its own.
class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return const SizedBox(
        height: 8,
        width: 8,
        child: DecoratedBox(
          decoration: BoxDecoration(color: MngColors.onPrimary, shape: BoxShape.circle),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Each dot is a third of a cycle behind the one before it, which is
            // what reads as a travelling pulse rather than a flash.
            final phase = (_c.value - i / 3) % 1.0;
            final scale = 0.6 + 0.4 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
            return Container(
              width: 8,
              height: 8,
              margin: EdgeInsets.only(right: 5.w),
              decoration: BoxDecoration(
                color: MngColors.onPrimary.withValues(alpha: 0.45 + 0.55 * scale),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}
