import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The animated start of both apps.
///
/// One car, one logo, one hand-off, in that order and no screen change until the
/// end:
///
/// 1. A car drives in from the right and decelerates to a stop in the middle.
/// 2. It settles -- a small dip, because a car that stops dead looks like a
///    graphic rather than a vehicle.
/// 3. The logo drops in and bounces to rest above the car.
/// 4. It holds, so the mark is readable for a beat rather than flashing past.
/// 5. The car accelerates away to the left.
/// 6. The splash opens and the [child] underneath is revealed.
///
/// ## Why it is drawn rather than a video
///
/// A video or a Lottie file has to be bought, licensed, or both, and this project
/// spends nothing. Everything here is `CustomPainter` and `AnimationController`,
/// which means it is free, it scales to any screen without a second asset, it
/// recolours with the theme, and it is testable with `pumpAndSettle` instead of
/// needing a golden frame comparison.
///
/// ## Why [child] rather than `onDone`
///
/// The destination is built *underneath* while the car is still driving. That is
/// what makes step 6 a real reveal rather than a fade between two routes, and it
/// is why a slow session restore is invisible: the session resolves during the
/// animation instead of after it, so nothing is ever shown loading that did not
/// have to be.
///
/// The handover is guarded by [_handedOver] so a rebuild cannot reveal twice.
class MngSplashScreen extends StatefulWidget {
  const MngSplashScreen({
    super.key,
    required this.child,
    required this.logo,
    this.tagline = 'Make a beeline across the city',
    // **White, not the brand gold.**
    //
    // This was gold first, and the handset screenshot showed why that cannot
    // work: the logo is gold, the car is gold, so the one thing the animation
    // exists to show was the one thing invisible on screen. The mark was there,
    // on time, at the right size -- and completely unreadable. Both were only
    // visible because of their dark tyres and windows.
    //
    // The logo's own artwork is gold-on-white, so white is also the colour it was
    // drawn for. The gold stays where it belongs: on the car, on the logo, on the
    // tagline -- as the subject rather than the stage.
    this.background = MngColors.page,
    this.onForeground = MngColors.textPrimary,
  });

  /// What the splash opens onto: the sign-in screen, or the dashboard.
  final Widget child;

  /// The brand mark, as an asset. Supplied by the app rather than hard-coded so
  /// the rider and driver apps can carry their own logo while sharing this.
  final ImageProvider logo;

  /// Under the logo. Null removes it, which the driver app uses because its own
  /// logo already carries a wordmark underneath.
  final String? tagline;

  final Color background;
  final Color onForeground;

  @override
  State<MngSplashScreen> createState() => _MngSplashScreenState();
}

class _MngSplashScreenState extends State<MngSplashScreen>
    with SingleTickerProviderStateMixin {
  /// Long enough for a car to arrive, stop, hand over the logo and leave, and
  /// short enough that nobody is waiting on it.
  ///
  /// Split into named phases below rather than tuned as one number, because the
  /// only thing anyone ever wants to change is "how long does it hold", and that
  /// is one field here rather than a curve boundary.
  static const Duration _duration = Duration(milliseconds: 4600);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _duration,
  );

  /// Where the car is, as a fraction of the screen width it starts off-screen at.
  ///
  /// `1.0` is centred, `0.0` is off the right edge, `-1.0` off the left. Named
  /// because the three phases read as three answers to "where is the car" and
  /// one number with three curves says the same thing with less room to be wrong.
  late final Animation<double> _arrive = CurvedAnimation(
    parent: _c,
    // `easeOutQuart` rather than `easeOutCubic`: a car braking has a long, flat
    // tail, and a cubic's is short enough that it reads as a snap to a stop.
    curve: const Interval(0.00, _arriveEnd, curve: Curves.easeOutQuart),
  );

  late final Animation<double> _settle = CurvedAnimation(
    parent: _c,
    curve: const Interval(_arriveEnd, _settleEnd, curve: Curves.easeOut),
  );

  late final Animation<double> _drop = CurvedAnimation(
    parent: _c,
    // `bounceOut`, not `easeOutBounce`: Flutter has no curve called `easeOutBounce`.
    // `bounceOut` is the one that drops and settles, which is the shape wanted
    // here -- the logo falls past its resting place and comes back a little.
    curve: const Interval(_settleStart, _dropEnd, curve: Curves.bounceOut),
  );

  late final Animation<double> _leave = CurvedAnimation(
    parent: _c,
    // Accelerating away, so the opposite curve to arriving. A car that eases out
    // on its way off looks like it is being sucked away.
    curve: const Interval(_leaveStart, _leaveEnd, curve: Curves.easeInCubic),
  );

  /// The artwork's own opacity: up while it is the whole screen, down as the
  /// opening reveal eats it.
  late final Animation<double> _artOpacity = CurvedAnimation(
    parent: _c,
    curve: const Interval(_revealStart, 1.0, curve: Curves.easeIn),
  );

  late final Animation<double> _reveal = CurvedAnimation(
    parent: _c,
    curve: const Interval(_revealStart, 1.0, curve: Curves.easeInOutCubic),
  );

  static const double _arriveEnd = 0.26;
  static const double _settleStart = 0.26;
  static const double _settleEnd = 0.33;
  static const double _dropEnd = 0.52;
  static const double _leaveStart = 0.70;
  static const double _leaveEnd = 0.90;
  static const double _revealStart = 0.88;

  bool _handedOver = false;

  @override
  void initState() {
    super.initState();
    // `MediaQuery` is not readable in `initState`, so reduced motion is resolved
    // on the first frame and the animation skipped there.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _start() {
    if (!mounted) return;
    if (MediaQuery.of(context).disableAnimations) {
      _handedOver = true;
      setState(() {});
      return;
    }
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final childVisible = _handedOver || _reveal.value > 0;
        return Stack(
          fit: StackFit.expand,
          children: [
            // **Always mounted, and `Offstage` until the reveal.**
            //
            // This was written the obvious way first -- `if (childVisible)
            // widget.child` -- and a test caught it at once: the child did not
            // mount until `_reveal.value` first exceeded zero, which is at 88% of
            // the sequence. So the destination was built *after* almost the whole
            // animation, which is precisely what taking a child was meant to
            // avoid: a slow session restore would still have shown a blank screen,
            // only later.
            //
            // `Offstage` rather than `Opacity(0)` because it keeps the subtree
            // alive and building -- the whole point -- while removing it from the
            // accessibility tree and from `find` by default, so nothing behind the
            // splash can be read or tapped.
            Offstage(offstage: !childVisible, child: widget.child),
            if (!_handedOver)
              ClipPath(
                clipper: _SplashRevealClipper(1 - _reveal.value),
                child: ColoredBox(color: widget.background, child: _artwork()),
              ),
          ],
        );
      },
    );
  }

  Widget _artwork() {
    return Opacity(
      opacity: 1 - _artOpacity.value,
      child: LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth;
          final height = box.maxHeight;

          // The car travels a distance the wheels can be turned by, which is what
          // makes them turn: a rotating wheel on a stationary car is a fidget,
          // and one that turns faster than the car moves is a different fidget.
          final travelIn = width * _arrive.value;
          final travelOut = width * _leave.value;
          final spin = _wheelTurns(travelIn + travelOut);

          return Stack(
            clipBehavior: Clip.none,
            children: [
              _car(
                centreX:
                    width / 2 +
                    (1 - _arrive.value) * width -
                    _leave.value * width * 1.4,
                baselineY: height * 0.62,
                carWidth: math.min(width * 0.46, 190),
                wheelTurns: spin,
                // Mirrored while it leaves, so the car drives off the way it came
                // in rather than sliding backwards.
                mirrored: _leave.value > 0.001,
                dip: _settle.value,
              ),
              _logo(width: width, height: height),
            ],
          );
        },
      ),
    );
  }

  /// The logo, dropped in above the car.
  Widget _logo({required double width, required double height}) {
    final tagline = widget.tagline;
    return Positioned.fill(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Transform.translate(
            offset: Offset(0, -height * 0.22 * (1 - _drop.value)),
            child: Transform.scale(
              scale: 0.82 + 0.18 * _drop.value,
              child: Opacity(
                // Fades in over the first third of its own drop rather than with
                // it, so the bounce lands on an already-visible mark instead of
                // arriving with the last of the motion.
                opacity: math.min(1, _drop.value * 3),
                child: Image(
                  image: widget.logo,
                  width: width * 0.56,
                  fit: BoxFit.contain,
                  // The asset is transparent, so it sits on the brand colour with
                  // no plate behind it. A logo with a white box around it is the
                  // single thing that would make this animation look broken.
                  errorBuilder: (context, error, stack) =>
                      const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          if (tagline != null && tagline.isNotEmpty) ...[
            SizedBox(height: height * 0.03),
            Opacity(
              opacity: math.min(1, math.max(0, (_drop.value - 0.5) * 2)),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: width * 0.12),
                child: Text(
                  tagline,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.onForeground,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The car, drawn as a side profile facing right.
  Widget _car({
    required double centreX,
    required double baselineY,
    required double carWidth,
    required double wheelTurns,
    required bool mirrored,
    required double dip,
  }) {
    final carHeight = carWidth * 0.42;
    return Positioned(
      left: centreX - carWidth / 2,
      top: baselineY - carHeight + carHeight * 0.09 * dip,
      width: carWidth,
      height: carHeight,
      child: Transform.scale(
        // `-1` on x flips the painter, so the wheels' tread and the slope of the
        // windscreen both point the way it is travelling.
        scaleX: mirrored ? -1 : 1,
        child: CustomPaint(
          painter: _CarPainter(
            body: widget.background,
            ink: widget.onForeground,
            wheelTurns: wheelTurns,
            // A shallow dip at the moment of stopping. Half the car's height at
            // full squash would be a cartoon bounce; this is a suspension
            // settling.
            squash: dip * 0.09,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// How far the wheels have turned, in turns.
  ///
  /// Circumference over the wheel diameter, so the rotation matches the ground
  /// covered rather than being a free-running spin.
  double _wheelTurns(double distance) {
    final wheelRadius = _CarPainter.wheelRadiusFraction * 1.0;
    final circumference = 2 * math.pi * wheelRadius;
    if (circumference <= 0) return 0;
    return distance / circumference;
  }
}

/// Reveals the destination by eating a shrinking rectangle out of the splash.
///
/// A rectangle rather than a circle because the artwork is a wide, calm band and
/// a circular iris would pinch the sides of it first. Shrinking towards the centre
/// rather than sliding in from an edge because the car has just driven off to the
/// left, and an edge wipe would come back through where it left.
class _SplashRevealClipper extends CustomClipper<Path> {
  const _SplashRevealClipper(this.progress);

  /// `1.0` is the whole screen, `0.0` is nothing left.
  final double progress;

  @override
  Path getClip(Size size) {
    final t = progress.clamp(0.0, 1.0);
    final width = size.width * t;
    final height = size.height * t;
    return Path()..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: width,
          height: height,
        ),
        // Rounded in proportion to what is left, so the last sliver is still a
        // rounded rect rather than a hard line across the screen.
        Radius.circular(math.min(width, height) * 0.12),
      ),
    );
  }

  @override
  bool shouldReclip(_SplashRevealClipper old) => old.progress != progress;
}

/// A side-profile car, facing right.
///
/// Drawn rather than assembled from icons because the animation needs three
/// things an icon cannot give: it faces left as well as right, its wheels turn
/// with the ground it covers, and it squashes when it stops.
class _CarPainter extends CustomPainter {
  _CarPainter({
    required this.body,
    required this.ink,
    required this.wheelTurns,
    required this.squash,
  });

  /// The wheel radius as a fraction of the car's height.
  ///
  /// A constant rather than a parameter because both wheels have to be the same
  /// size and [wheelTurns] is computed against it from outside.
  static const double wheelRadiusFraction = 0.21;

  final Color body;
  final Color ink;
  final double wheelTurns;
  final double squash;

  /// A darker version of [body], used for the outline and the lower shading.
  ///
  /// Not a constant: it is derived, so a caller who changes [body] gets an
  /// outline that still contrasts. A gold car with no outline on white is a pale
  /// shape with pale edges, and the silhouette stops reading at arm's length.
  Color get _edge => Color.lerp(body, const Color(0xFF6B4A00), 0.45)!;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Squash is applied about the baseline, so the car settles onto its wheels
    // rather than shrinking toward its own middle and floating.
    canvas.save();
    canvas.translate(0, h);
    canvas.scale(1 - squash * 0.5, 1 - squash);
    canvas.translate(0, -h);

    final wheelR = h * wheelRadiusFraction;
    final groundY = h - wheelR;
    final bodyColour = Color.lerp(body, Colors.black, 0.10)!;
    final glassColour = Color.lerp(ink, Colors.white, 0.10)!;

    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.13)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    // Contact shadow first, so everything else sits on top of it.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.5, groundY + wheelR * 0.92),
        width: w * 0.86,
        height: wheelR * 0.5,
      ),
      shadow,
    );

    // --- body -------------------------------------------------------------
    // A saloon silhouette: low bonnet, rising shoulder line, tapering boot. Drawn
    // as one path so the shoulder and the roof are the same shape rather than a
    // rectangle with a roof laid on it.
    final silhouette = Path()
      ..moveTo(w * 0.03, groundY)
      ..lineTo(w * 0.03, groundY - h * 0.30)
      ..quadraticBezierTo(
        w * 0.10,
        groundY - h * 0.36,
        w * 0.22,
        groundY - h * 0.40,
      )
      ..lineTo(w * 0.34, groundY - h * 0.74)
      ..quadraticBezierTo(
        w * 0.40,
        groundY - h * 0.88,
        w * 0.56,
        groundY - h * 0.88,
      )
      ..quadraticBezierTo(
        w * 0.72,
        groundY - h * 0.88,
        w * 0.79,
        groundY - h * 0.62,
      )
      ..lineTo(w * 0.92, groundY - h * 0.52)
      ..quadraticBezierTo(
        w * 0.99,
        groundY - h * 0.48,
        w * 0.99,
        groundY - h * 0.36,
      )
      ..lineTo(w * 0.99, groundY)
      ..close();

    canvas.drawPath(silhouette, Paint()..color = bodyColour);

    // Outline, so the silhouette reads on a light background. Without it the
    // car's edges are the same value as the page and the whole shape dissolves
    // into it -- the body is only a few percent off white already.
    canvas.drawPath(
      silhouette,
      Paint()
        ..color = _edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.035
        ..strokeJoin = StrokeJoin.round,
    );

    // --- glass ------------------------------------------------------------
    final glass = Path()
      ..moveTo(w * 0.38, groundY - h * 0.70)
      ..lineTo(w * 0.55, groundY - h * 0.83)
      ..lineTo(w * 0.55, groundY - h * 0.70)
      ..close();
    canvas.drawPath(glass, Paint()..color = glassColour);

    final glassRear = Path()
      ..moveTo(w * 0.59, groundY - h * 0.83)
      ..lineTo(w * 0.74, groundY - h * 0.83)
      ..quadraticBezierTo(
        w * 0.75,
        groundY - h * 0.74,
        w * 0.75,
        groundY - h * 0.70,
      )
      ..lineTo(w * 0.59, groundY - h * 0.70)
      ..close();
    canvas.drawPath(glassRear, Paint()..color = glassColour);

    // --- lamps ------------------------------------------------------------
    // Headlight at the front (right), tail at the back. Small, but they are what
    // make the shape read as facing right rather than being symmetrical.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.90, groundY - h * 0.46, w * 0.075, h * 0.11),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFFFFF3C4),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.035, groundY - h * 0.40, w * 0.055, h * 0.10),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFFD64545),
    );

    // --- wheels -----------------------------------------------------------
    _wheel(canvas, Offset(w * 0.26, groundY), wheelR);
    _wheel(canvas, Offset(w * 0.78, groundY), wheelR);

    canvas.restore();
  }

  void _wheel(Canvas canvas, Offset centre, double r) {
    final tyre = Paint()
      ..color = const Color(0xFF2A2A2A)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(centre, r, tyre);

    final hub = Paint()
      ..color = Color.lerp(ink, Colors.white, 0.55)!
      ..style = PaintingStyle.fill;
    canvas.drawCircle(centre, r * 0.44, hub);

    // Spokes, rotated by the distance covered. Three of them so the rotation is
    // visible: a symmetric wheel with one mark on it looks still while spinning.
    final spoke = Paint()
      ..color = const Color(0xFF2A2A2A)
      ..strokeWidth = r * 0.16
      ..strokeCap = StrokeCap.round;
    final turn = wheelTurns * 2 * math.pi;
    for (var i = 0; i < 3; i++) {
      final a = turn + i * (2 * math.pi / 3);
      canvas.drawLine(
        centre + Offset(math.cos(a), math.sin(a)) * (r * 0.18),
        centre + Offset(math.cos(a), math.sin(a)) * (r * 0.38),
        spoke,
      );
    }
  }

  @override
  bool shouldRepaint(_CarPainter old) =>
      old.wheelTurns != wheelTurns ||
      old.squash != squash ||
      old.body != body ||
      old.ink != ink;
}
