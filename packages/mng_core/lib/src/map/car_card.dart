import 'package:flutter/material.dart';

import '../models/category.dart';

/// The driver's car, as a card: a car, its name, and its plate.
///
/// ## Why this is not `car_topdown_icon.dart`
///
/// That module draws a *plan* view, and its own header explains why: "the plan
/// view is what makes this read as a vehicle at map scale", because a car seen
/// from directly above is recognisable by its silhouette -- long, narrow, a cabin
/// inset from the body, glass at each end. Every one of those arguments is about
/// a sprite sixteen pixels wide.
///
/// At card size the same reasoning inverts. A plan view at 108 logical pixels is
/// a diagram: it shows the roof and nothing else, so there is no bonnet, no
/// windscreen rake, no wheel arches in profile and no sense of a bonnet line. It
/// reads as a floor plan of a car rather than as a car. The silhouette that works
/// at map scale is the thing that stops working once the map is gone.
///
/// So this draws a three-quarter view instead: from the front, slightly above and
/// to one side, which is the angle a car photograph is almost always taken from
/// and therefore the one a driver recognises as *this is my car*. The plan sprite
/// keeps its job on the map, where it is the right answer.
///
/// Drawn rather than photographed, for the same reason that module gives: a bitmap
/// of a car cannot be reviewed in a diff, and here the entire design is that the
/// paint follows the ride category. A tint cannot be applied to a photograph
/// without looking like a filter, and a filter on a car reads as a filter on the
/// *category* -- the one thing the rider is meant to read off it.
///
/// ## What the tier colour is for
///
/// A car card is the main place a rider learns what tier they booked, and it is
/// the last screen before they get in. So the tier has to be legible without
/// reading a word, and it is legible from the paint.
///
/// The colour is [RideCategory.color], not a colour chosen here. There is exactly
/// one answer in the codebase to "what colour is a premium car" and it already
/// exists; a second one is how the card and the fare badge end up disagreeing.
///
/// It is the paint, not a coloured panel behind the car. A tint on the body makes
/// a car of that tier; a tint on a background makes the card look like a category
/// filter that happens to contain a car.
class CarCard extends StatelessWidget {
  const CarCard({
    super.key,
    required this.make,
    required this.model,
    required this.plate,
    required this.tier,
    this.category,
    this.width,
  });

  /// Empty make and model render as "No vehicle added yet" and an empty plate as
  /// "No number plate yet". A driver who has not saved a vehicle has not done
  /// anything wrong, and a card with two blank rows in it reads as a failure
  /// rather than as an absence.
  final String make;
  final String model;
  final String plate;
  final RideCategory tier;

  /// Body style -- "Sedan", "SUV". Shown when there is one and dropped when there
  /// is not, rather than showing an empty label for a field nobody filled in.
  final String? category;

  final double? width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final rawName = '$make $model'.trim().replaceAll(RegExp(r'\s+'), ' ');
    final name = rawName.isEmpty ? 'No vehicle added yet' : rawName;
    final hasPlate = plate.trim().isNotEmpty;
    final bodyStyle = category?.trim() ?? '';
    // The tier is the fallback for the subtitle, not the primary: a driver who
    // filled in "Sedan" wants to see "Sedan", and the tier is already on the
    // paint and in the fare. Dropping it to a line of text nobody reads would be
    // decoration, and would leave a driver who saved no body style with a blank.
    final subtitle = bodyStyle.isNotEmpty ? bodyStyle : tier.label;

    return Container(
      width: width,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 108 wide: enough for the three-quarter view to read as a car
              // rather than as a blob, and narrow enough to leave room for the
              // name beside it on a 360 logical pixel card.
              SizedBox(
                width: 108,
                height: 72,
                child: RepaintBoundary(
                  child: CustomPaint(painter: CarPainter(body: tier.color)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      key: const Key('carCardName'),
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      key: const Key('carCardTier'),
                      style: theme.textTheme.bodySmall?.copyWith(color: tier.color),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.pin_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  hasPlate ? plate.trim().toUpperCase() : 'No number plate yet',
                  key: const Key('carCardPlate'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    // A plate is read out at a pick-up point and typed into
                    // messages, so the glyphs are letterspaced and bold. It is
                    // the one string on this card a rider has to get exactly
                    // right, and `Flexible` because a long African plate format
                    // on a narrow card would otherwise overflow rather than
                    // ellipsise.
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                    color: hasPlate ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A car, from the front and slightly above and to one side.
///
/// Public, and public on purpose. The claim this type makes -- that the paint
/// follows the ride category -- cannot be tested through [CarCard], because a card
/// constructed with a tier proves only that the card was constructed. Pushing the
/// paint and reading the pixels back is the only way to check that the *car* is
/// the tier's colour, and that needs the painter to be reachable.
///
/// Painted rather than assembled from widgets: a car is one silhouette, and
/// splitting it into a container per panel makes the joins visible at every size.
/// The parts are drawn back to front -- shadow, far flank, body, bonnet, glass,
/// lamps, wheels -- so overlap does the occlusion, which is what makes it read
/// as solid without a single gradient.
class CarPainter extends CustomPainter {
  const CarPainter({required this.body});

  /// The base colour, from [RideCategory.color]. The far flank and the bonnet are
  /// derived from it rather than chosen, so one tier is one decision.
  final Color body;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final p = Paint()..isAntiAlias = true;

    // Ground shadow first, offset down and right: the light is from above and to
    // the left, matching the plan sprite's convention, so the two views look like
    // the same object under the same light.
    p.color = const Color(0x22000000);
    canvas.drawOval(Rect.fromLTWH(w * 0.06, h * 0.70, w * 0.88, h * 0.20), p);

    // Far flank -- the side turned away, visible past the near flank at this
    // angle. Darker, because it faces the light less.
    p.color = _shift(body, lightness: -0.16);
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.18, h * 0.54)
        ..lineTo(w * 0.32, h * 0.33)
        ..lineTo(w * 0.86, h * 0.33)
        ..lineTo(w * 0.90, h * 0.55)
        ..close(),
      p,
    );

    // The near flank, running from the front arch to the rear.
    p.color = body;
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.12, h * 0.58)
        ..lineTo(w * 0.28, h * 0.39)
        ..lineTo(w * 0.84, h * 0.39)
        ..lineTo(w * 0.88, h * 0.60)
        ..close(),
      p,
    );

    // Bonnet, lighter than the flank because it faces up into the light. This one
    // change is what stops the shape reading as a flat block.
    p.color = _shift(body, lightness: 0.10);
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.15, h * 0.57)
        ..lineTo(w * 0.31, h * 0.36)
        ..lineTo(w * 0.62, h * 0.36)
        ..lineTo(w * 0.50, h * 0.56)
        ..close(),
      p,
    );

    // Glass, as two panes, because the screen is raked. One shape reads as a van.
    p.color = const Color(0xFF2B3440);
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.34, h * 0.385)
        ..lineTo(w * 0.60, h * 0.385)
        ..lineTo(w * 0.53, h * 0.55)
        ..lineTo(w * 0.31, h * 0.55)
        ..close(),
      p,
    );
    p.color = const Color(0xFF54636F);
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.36, h * 0.405)
        ..lineTo(w * 0.56, h * 0.405)
        ..lineTo(w * 0.52, h * 0.52)
        ..lineTo(w * 0.35, h * 0.52)
        ..close(),
      p,
    );

    // Grille, then the front lamp. White at the front and red at the back are what
    // make the orientation readable when the card is small.
    p.color = const Color(0xFF1A1D21);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.16, h * 0.615, w * 0.30, h * 0.09),
        Radius.circular(h * 0.03),
      ),
      p,
    );
    p.color = const Color(0xFFF6F1E3);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.175, h * 0.635, w * 0.07, h * 0.05),
        Radius.circular(h * 0.02),
      ),
      p,
    );

    // Rear lamp, at the tail on the right.
    p.color = const Color(0xFFD2402F);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.82, h * 0.42, w * 0.05, h * 0.08),
        Radius.circular(h * 0.02),
      ),
      p,
    );

    // Wheels last, so they sit over the flank -- which is what puts the near
    // wheel in front of the body and reads as depth.
    p.color = const Color(0xFF15171A);
    const frontWheel = (0.27, 0.74);
    const rearWheel = (0.76, 0.74);
    for (final wheel in [frontWheel, rearWheel]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            w * wheel.$1 - w * 0.055,
            h * wheel.$2 - h * 0.17,
            w * 0.11,
            h * 0.34,
          ),
          Radius.circular(w * 0.05),
        ),
        p,
      );
    }
    // A rim highlight, so a wheel is not a black hole at small sizes.
    p.color = const Color(0xFFB9BEC4);
    for (final wheel in [frontWheel, rearWheel]) {
      canvas.drawCircle(Offset(w * wheel.$1, h * wheel.$2 - h * 0.10), w * 0.022, p);
    }
  }

  /// Nudge a colour's lightness, clamped.
  ///
  /// HSL rather than a black overlay with alpha, because an alpha overlay also
  /// moves saturation and hue -- a dark green body goes grey-blue rather than
  /// dark green, which is not the same car.
  static Color _shift(Color c, {required double lightness}) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness + lightness).clamp(0.0, 1.0)).toColor();
  }

  @override
  bool shouldRepaint(covariant CarPainter oldDelegate) => oldDelegate.body != body;
}