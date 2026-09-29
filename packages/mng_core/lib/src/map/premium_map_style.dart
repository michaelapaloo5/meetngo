/// The one map style, and the names the style and the apps have to agree on.
///
/// Both apps draw from this rather than from a remote style URL, and that is a
/// deliberate change from the `liberty` style this replaced. A remote style is
/// a remote dependency on someone else's taste: it can be repainted overnight,
/// a layer this app depends on can disappear, and none of it is reviewable in a
/// diff. Shipping the JSON here means the map's entire appearance is a file in
/// this repository that a reviewer can read, and the only thing still fetched
/// over the network is OpenStreetMap's geometry — which is data, not design.
///
/// The file lives in `assets/` rather than `lib/` because MapLibre reads a
/// bundled style by asset path, not from Dart source. See
/// [kPremiumMapStyleAsset].
library;

import 'package:flutter/services.dart' show rootBundle;

/// The bundled style, as the asset key MapLibre is handed.
///
/// The `packages/` prefix is how Flutter addresses an asset that belongs to a
/// dependency rather than to the app, and it is required: without it the
/// lookup silently fails and the map draws nothing.
///
/// Loaded through [premiumMapStyleJson] rather than referenced directly, so
/// there is one way to get the style's text and both maps get it.
const String kPremiumMapStyleAsset =
    'packages/mng_core/assets/maps/ride_premium.json';

/// The style JSON, loaded from the bundle.
///
/// For MapLibre's `styleString`, which accepts a raw style string as well as a
/// URL or an asset path. A URL would make the map's appearance depend on the
/// network; the bundled text cannot.
///
/// Returns the empty string if the asset is missing, which is a build mistake
/// rather than a runtime condition — an asset declared in `pubspec.yaml` and
/// present in the repository cannot fail to load. Handing MapLibre an empty
/// string makes it complain loudly, which beats passing a path that quietly
/// renders a blank canvas.
Future<String> premiumMapStyleJson() async {
  final text = await rootBundle.loadString(kPremiumMapStyleAsset);
  return text;
}

/// The image name of the top-down car sprite, as the style's
/// `moving-car-icon` layer declares it in `icon-image`.
///
/// One name in two places — this constant and `icon-image` in the style JSON —
/// which is exactly the kind of duplication that breaks silently, because a
/// symbol layer whose `icon-image` matches nothing does not throw; it just draws
/// nothing and the car vanishes with no error anywhere. [premiumMapStyleJson]
/// is checked against this in the tests.
const String kCarTopdownIconName = 'car-topdown';

/// The style's GeoJSON source holding moving vehicles.
const String kVehicleSourceId = 'vehicles';

/// The style's symbol layer that draws them.
const String kMovingCarLayerId = 'moving-car-icon';

/// The GeoJSON `bearing` property the style rotates the car by.
///
/// Degrees clockwise from north, which is what a compass heading already is and
/// what `icon-rotation-alignment: map` expects, so no conversion happens
/// anywhere in the app. The sprite is drawn nose-up, and `icon-rotate` turns it
/// clockwise from up, so a bearing of 90 puts the nose pointing east.
const String kVehicleBearingProperty = 'bearing';

/// Palette the style is drawn in, as CSS hex.
///
/// Mirrors the `mng:palette` block in the style JSON. It is duplicated rather
/// than read out of the style at runtime because the apps need these values to
/// match their own overlays to the map — a route line in a slightly different
/// blue on a slightly different land colour reads as two different products.
abstract final class PremiumMapPalette {
  /// The land behind everything, and the colour a no-tile area falls back to.
  static const String land = '#F4F4F6';

  /// Water, desaturated so it sits under the roads rather than shouting.
  static const String water = '#C4D3DF';

  /// Parks and other green space, soft enough to read as ground cover.
  static const String park = '#E2F0D9';

  /// Every road. White, not gray: on a `#F4F4F6` background the roads are
  /// lighter than the land, which is the Uber/Bolt convention and the one that
  /// makes a route drawn in a saturated colour legible.
  static const String road = '#FFFFFF';

  /// The outline separating highways from the local streets beneath them.
  static const String roadCasing = '#E0E0E5';

  /// The extruded buildings.
  static const String building = '#E5E7EB';
}
