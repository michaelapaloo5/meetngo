import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../trip/trip_copy.dart';

import '../data/place_service.dart';
import '../data/saved_place_repository.dart';
import '../home/widgets/category_chips.dart';
import '../map/ride_map.dart';
import 'schedule_picker.dart';

/// Everything the rider decided on the confirm page, and nothing else.
///
/// A value rather than a callback per field, because the draft is handed back
/// through `Navigator.pop` as well as to `onSubmit` and two routes carrying four
/// fields each is four chances to forget one. Adding a fifth field here is one
/// edit in one place.
///
/// [scheduledFor] null means now. It is local time as chosen, not UTC, because
/// the rider picked a wall-clock moment and the conversion happens once, at the
/// repository, in `toUtc()`.
class RouteDraft {
  const RouteDraft({
    required this.pickup,
    required this.dropoff,
    required this.category,
    this.scheduledFor,
  });

  final TripStop pickup;
  final TripStop dropoff;
  final RideCategory category;

  /// When the rider wants it, or null for now.
  final DateTime? scheduledFor;

  /// Whether this draft books for later.
  bool get isScheduled => scheduledFor != null;

  /// The same draft, booked immediately.
  RouteDraft asNow() =>
      RouteDraft(pickup: pickup, dropoff: dropoff, category: category);
}

/// A short, real place name to pre-fill the naming field with.
///
/// The first comma-separated segment of [address]: "Dansoman Police Station,
/// General Acheampong High Street, Dansoman" becomes "Dansoman Police Station".
///
/// It used to pre-fill the whole address, which was wrong in two ways at once.
/// The field is a *name* -- "So you can tap it next time" says so -- and a saved
/// place is drawn as a chip, where a full address overflows the row and pushes
/// the delete button off the edge of the screen. The address is still what gets
/// stored and what the chip sends a car to; only the name is shortened, and it is
/// shortened to a real place rather than to a number of characters.
///
/// The segment is truncated to [maxLength] as a backstop, because an address
/// with no comma in it is one long name and the field still has to be usable.
String defaultPlaceName(String address, {int maxLength = 40}) {
  final trimmed = address.trim();
  if (trimmed.isEmpty) return '';
  final first = trimmed.split(',').first.trim();
  final name = first.isEmpty ? trimmed : first;
  if (name.length <= maxLength) return name;
  return '${name.substring(0, maxLength - 1).trimRight()}…';
}

/// The dialog that names a saved place.
///
/// Owns its own controller so it can dispose it in [dispose], which happens
/// after the route has finished animating out rather than the instant the caller
/// sees the future complete. See [_RouteConfirmPageState._askForName].
class _NamePlaceDialog extends StatefulWidget {
  const _NamePlaceDialog({required this.address});

  final String address;

  @override
  State<_NamePlaceDialog> createState() => _NamePlaceDialogState();
}

class _NamePlaceDialogState extends State<_NamePlaceDialog> {
  late final TextEditingController _name = TextEditingController(
    text: defaultPlaceName(widget.address),
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save this place'),
      content: TextField(
        key: const Key('savedPlaceNameField'),
        controller: _name,
        autofocus: true,
        // 40, and the pre-fill is now a short real place name rather
        // than the whole address (see [defaultPlaceName]). Between them they have
        // to fit: the saved place is drawn as a chip, and a name longer than the
        // chip overflows the row and pushes the delete button off the edge of the
        // screen -- which is exactly what happened with a 79-character name saved
        // from the handset. The column is unbounded `text`, so this is the only
        // cap anywhere, and it belongs here where the chip is.
        maxLength: 40,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Call it',
          // "So you can tap it next time" -- which is what the name is for. A
          // rider who thinks the name is the destination will type the whole
          // address and then wonder why the chip is unreadable.
          helperText: 'So you can tap it next time',
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancelSavePlace'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirmSavePlace'),
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Accra defaults used when the rider's own position is not available.
///
/// Both are real coordinates inside the pilot area so a route drafted without
/// a location fix still renders on the map. `kDefaultPickup` is the fallback
/// for "the rider declined or has no fix", not the normal path: the shell asks
/// the OS for a fix first and passes the answer in.
const kDefaultPickup = TripStop(
  'Pickup',
  GeoPoint(5.6037, -0.1870),
  'Osu, Accra',
);

/// The default destination, used only when the rider has not chosen one.
///
/// It is a real place and a plausible first trip, which is what makes it
/// dangerous: a sheet that opened on this and refused to change it produced a
/// ride to the same airport every single time, and the rider had no way to ask
/// for anywhere else. The field is editable now; this is only what it starts
/// as.
const kDefaultDropoff = TripStop(
  'Dropoff',
  GeoPoint(5.6052, -0.1660),
  'Airport Residential, Accra',
);

/// A pickup built from a real device fix.
///
/// The address is [label], not the coordinate. A `TripStop` needs an address
/// string and `"5.6037, -0.1870"` is not one: a rider reading the pickup they
/// are about to confirm has no way to tell that it is them, and it is the only
/// string on the screen that reads like a fault. The exact point travels in
/// [TripStop.point], and is drawn on the map and sent to the server, which is
/// where a coordinate belongs.
///
/// [label] is the reverse-geocoded place when the shell already has one, and
/// "Your location" when it does not.
TripStop pickupFromFix(GeoPoint point, {String? label}) =>
    TripStop('Pickup', point, label ?? 'Your location');

/// Pushes the confirm page and hands back the draft the rider confirmed.
///
/// A pushed page, not `showModalBottomSheet`. The sheet it replaces covered the
/// map it was describing and asked for four decisions at once; see
/// `DestinationSearchPage` for why the flow is two screens.
///
/// Returns null when the rider backs out, which is the ordinary case and not a
/// failure. The caller re-reads the rider's trip history either way, because a
/// ride they started from the home screen may finish while this page is open.
Future<RouteDraft?> pushRouteConfirmPage(
  BuildContext context, {
  required FareCalculator calc,
  required void Function(RouteDraft draft) onSubmit,
  required PlaceService places,
  TripStop? pickup,
  TripStop? dropoff,
  SavedPlaceRepository? saved,
  void Function(SavedPlace place)? onPlaceSaved,
}) {
  return Navigator.of(context).push<RouteDraft>(
    MaterialPageRoute<RouteDraft>(
      builder: (_) => RouteConfirmPage(
        calc: calc,
        onSubmit: onSubmit,
        places: places,
        pickup: pickup,
        dropoff: dropoff,
        saved: saved,
        onPlaceSaved: onPlaceSaved,
      ),
    ),
  );
}

class RouteConfirmPage extends StatefulWidget {
  const RouteConfirmPage({
    super.key,
    required this.calc,
    required this.onSubmit,
    required this.places,
    this.pickup,
    this.dropoff,
    this.saved,
    this.onPlaceSaved,
  });

  final FareCalculator calc;
  final void Function(RouteDraft draft) onSubmit;

  /// The geocoder, injected rather than reached for, so the sheet has no
  /// network in it and a test can drive it from a list.
  final PlaceService places;

  /// Where the rider is, when the OS said so. Null falls back to
  /// [kDefaultPickup] rather than refusing to open, because a rider who
  /// refused location permission can still book a ride from a remembered
  /// pickup, and a sheet that will not open is a worse answer than a default.
  final TripStop? pickup;

  /// Where the rider already decided to go, when they came from the search
  /// page.
  ///
  /// Null means they have not chosen one, and the page says so rather than
  /// quietly offering the demo destination. [kDefaultDropoff] is what a rider
  /// with no choice would get, and a ride to the same airport every single time
  /// is the outcome that default was dangerous for.
  final TripStop? dropoff;

  /// Where "save this place" writes, or null for nowhere.
  ///
  /// Null hides the control. A rider on a build with no saved places would
  /// otherwise get a bookmark button that opens a dialog and then does nothing,
  /// which is the worst kind of feature: it looks finished and is a trap.
  final SavedPlaceRepository? saved;

  /// Called after a place is saved, so the destination screen's chips can be
  /// there next time rather than one visit stale.
  final void Function(SavedPlace place)? onPlaceSaved;

  @override
  State<RouteConfirmPage> createState() => _RouteConfirmPageState();
}

class _RouteConfirmPageState extends State<RouteConfirmPage> {
  late TripStop _pickup = widget.pickup ?? kDefaultPickup;
  // No demo destination as a starting value. The search page is where a
  // destination is chosen, and arriving here without one means the rider
  // backed out of that and came in another way -- so the field is empty and
  // says what it wants, rather than quietly booking everyone to the airport.
  late TripStop? _dropoff = widget.dropoff;
  RideCategory _category = RideCategory.standard;

  /// When the rider wants the ride, or null for now.
  ///
  /// Null is the default rather than "15 minutes from now" because a rider who
  /// has not thought about it wants a car now, and a picker that opens on a
  /// suggestion is a picker that books the wrong time.
  DateTime? _scheduledFor;

  /// Whether the map picker is open over the fields.
  bool _pickingOnMap = false;

  /// Which stop the open map is setting.
  _Field _mapField = _Field.pickup;

  /// Guards a reverse-geocode answer against the rider having moved on.
  ///
  /// Nominatim is a free public service and a lookup takes real time, so a
  /// rider can tap a point, then tap another, then type a search, all before
  /// the first answer lands. Without this the *first* answer would arrive last
  /// and overwrite the second tap, and the pickup would silently be the place
  /// the rider rejected. A counter rather than a comparison of the point,
  /// because two taps on nearby corners can resolve to the same place name.
  int _pickToken = 0;

  /// Which field the rider is editing, or null when neither has focus.
  _Field? _editing;

  /// Live results for whichever field is being edited.
  List<PlaceSuggestion> _results = const [];
  bool _searching = false;

  /// Debounce handle, so typing does not fire a request per keystroke.
  ///
  /// The usage policy caps this service at one request a second and treats
  /// autocomplete traffic as unacceptable. One request per pause in typing is
  /// the difference between that and a policy violation.
  Timer? _debounce;

  /// The trip's own state, so the list can say "nothing matched" honestly.
  String _query = '';

  /// Long enough to be a pause rather than a keystroke, and short enough that
  /// the list feels attached to the keyboard.
  static const Duration _searchDelay = Duration(milliseconds: 450);

  /// The distance, or null while there is no destination to measure from.
  ///
  /// Null rather than zero, and computed lazily at the point of use. A `0.0`
  /// here would produce a fare of a few pesewas for a ride with no destination,
  /// which is a price and a wrong one; and a non-null `get` that force-unwraps
  /// would crash the build of a screen whose entire job is to let a rider fix a
  /// missing destination.
  double? get _distanceKm =>
      _dropoff == null ? null : _pickup.point.distanceKmTo(_dropoff!.point);

  int? get _driveMinutes {
    final km = _distanceKm;
    return km == null ? null : (km / 24 * 60).round();
  }

  /// Whether there is enough on screen to book a ride.
  ///
  /// Without a destination there is no distance, no fare, and nothing to send.
  /// The button is disabled and says why, rather than being absent: a rider who
  /// cannot see why the button is dead will tap it repeatedly, and one who is
  /// not told a destination is missing will think the app lost what they typed.
  bool get _canSubmit => _dropoff != null;

  /// The name to print beside a pin being chosen, or null when that stop is not
  /// set.
  ///
  /// Read off the stop rather than hard-coded, because these two fields are what
  /// the rider is editing right now and the pin has to keep up with them. A stop
  /// that has been picked on the map and not yet geocoded keeps its placeholder
  /// text on the pin, which says something true.
  ///
  /// `stopLabel` rather than `.label`: some rows in this database carry a
  /// coordinate string where a label belongs, and this is the one function in
  /// the app that refuses to print one.
  String? _labelFor(TripStop? stop) {
    if (stop == null) return null;
    final label = stopLabel(stop);
    return label.isEmpty ? null : label;
  }

  ///
  /// Both defaults are in the same neighbourhood of Accra, so a rider who
  /// never touches either field gets a fare and a map that are perfectly
  /// plausible and entirely not what they asked for. Saying so beats letting
  /// them discover it on a receipt.
  bool get _isUneditedDefault =>
      _pickup.address == kDefaultPickup.address &&
      _dropoff?.address == kDefaultDropoff.address;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged(_Field field, String value) {
    setState(() {
      _editing = field;
      _query = value;
    });
    _debounce?.cancel();
    if (value.trim().length < kMinPlaceSearchChars) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    _debounce = Timer(_searchDelay, () => _runSearch(field, value));
  }

  Future<void> _runSearch(_Field field, String value) async {
    if (!mounted) return;
    setState(() => _searching = true);
    final found = await widget.places.search(value);
    if (!mounted) return;
    // A late answer for a field the rider has since left, or for a query they
    // have since edited, must not replace the list they are looking at.
    if (_editing != field || _query != value) return;
    setState(() {
      _results = found;
      _searching = false;
    });
  }

  void _choose(_Field field, PlaceSuggestion hit) {
    _debounce?.cancel();
    setState(() {
      final stop = TripStop(
        field == _Field.pickup ? 'Pickup' : 'Dropoff',
        hit.point,
        hit.label,
      );
      if (field == _Field.pickup) {
        _pickup = stop;
      } else {
        _dropoff = stop;
      }
      _editing = null;
      _query = '';
      _results = const [];
      _searching = false;
    });
  }

  /// Submits the draft and closes the page.
  ///
  /// The draft goes back through `Navigator.pop` as well as through
  /// [RouteConfirmPage.onSubmit], so a caller that pushed the page gets its
  /// draft without having to thread a callback through two navigators. The
  /// callback is the primary route; the pop is what lets the search page's own
  /// caller chain the flow.
  void _submit() {
    final destination = _dropoff;
    if (destination == null) return;
    final draft = RouteDraft(
      pickup: _pickup,
      dropoff: destination,
      category: _category,
      scheduledFor: _scheduledFor,
    );
    Navigator.of(context).pop<RouteDraft>(draft);
    widget.onSubmit(draft);
  }

  /// Replaces one of the two stops.
  void _setStop(_Field field, TripStop stop) {
    setState(() {
      if (field == _Field.pickup) {
        _pickup = stop;
      } else {
        _dropoff = stop;
      }
    });
  }

  /// A point tapped on the map, with its address looked up afterwards.
  ///
  /// The point is applied immediately and the address upgraded when it
  /// arrives, rather than waiting for the lookup. A rider who taps a spot and
  /// watches the field stay blank has no way to tell a slow geocoder from a
  /// broken one, and will tap again. "Picked on the map" is the honest
  /// placeholder: it says a point was chosen and says nothing about where,
  /// because as far as this app knows it does not yet know where.
  Future<void> _pickOnMap(GeoPoint point) async {
    final token = ++_pickToken;
    final field = _mapField;
    final label = field == _Field.pickup ? 'Pickup' : 'Dropoff';
    _setStop(field, TripStop(label, point, 'Picked on the map'));
    // The search list closes. A map tap and a search hit are the same decision
    // reached two ways, and leaving both open at once is only clutter.
    setState(() {
      _editing = null;
      _results = const [];
      _searching = false;
    });

    final name = await widget.places.reverse(point);
    // An answer that has been overtaken is dropped: see [_pickToken]. A failed
    // lookup leaves "Picked on the map" in place, which is the point. The ride
    // is still bookable and still goes to the right pin; the address is the
    // part the geocoder could not supply, and replacing the field with an
    // error would suggest the ride itself could not be booked.
    if (!mounted || token != _pickToken) return;
    if (name == null || name.line.trim().isEmpty) return;
    _setStop(field, TripStop(label, point, name.line));
  }

  /// Saves the destination under a name the rider picks.
  ///
  /// Here rather than on the search results, because this is the one moment the
  /// rider has just agreed to go somewhere and is looking at the full address.
  /// Saving it earlier would mean saving a place they had not checked.
  ///
  /// The **address** is what gets stored and what comes back onto the confirm
  /// screen. The name is only what the rider calls it, and it belongs on the
  /// chip. Storing the name as the address would put "Home" on a map pin.
  Future<void> _savePlace() async {
    final repository = widget.saved;
    final destination = _dropoff;
    if (repository == null || destination == null) return;

    final address = stopLabel(destination);
    final suggestion = await _askForName(context, address: address);
    if (suggestion == null || !mounted) return;

    final name = suggestion.trim();
    if (name.isEmpty) return;
    // Swallowed on purpose: the repository is upsert-shaped, so the only
    // failure a rider can cause is one where nothing changed for them, and a
    // "could not save" over a place that is already saved would be confusing
    // rather than useful.
    try {
      final row = await repository.save(
        SavedPlace(
          id: '',
          label: name,
          address: address,
          point: destination.point,
        ),
      );
      if (!mounted || row == null) return;
      widget.onPlaceSaved?.call(row);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            key: const Key('placeSavedSnack'),
            content: Text('$name saved'),
          ),
        );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            key: Key('placeSaveFailedSnack'),
            content: Text('Could not save that. Try again.'),
          ),
        );
    }
  }

  /// Asks what to call the place, defaulting to the place's own name.
  ///
  /// The default is the address rather than the empty string: a rider who taps
  /// through still gets something useful, and "Home" typed first is one tap
  /// fewer.
  ///
  /// Its own widget rather than an inline `AlertDialog`, because the controller
  /// has to be disposed by whoever built the field and not by whoever awaited
  /// the route. Doing it with `.whenComplete(controller.dispose)` disposed it the
  /// instant the route future completed -- which is *before* the dialog has
  /// finished animating out -- and the field threw
  /// "A TextEditingController was used after being disposed" on every save.
  Future<String?> _askForName(BuildContext context, {required String address}) {
    return showDialog<String>(
      context: context,
      builder: (_) => _NamePlaceDialog(address: address),
    );
  }

  void _openMapFor(_Field field) {
    setState(() {
      _pickingOnMap = true;
      _mapField = field;
      _editing = null;
      _results = const [];
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Quoted only once both ends exist. See [_distanceKm]: a quote against a
    // missing destination is a number, and a wrong number on a price is worse
    // than no number at all.
    final km = _distanceKm;
    final full = km == null
        ? null
        : widget.calc.quote(category: _category, distanceKm: km);
    // The fare the rider is quoted, and it is the fare they are charged.
    //
    // There is no second calculation here any more. There used to be: this
    // screen multiplied by 0.7 for the "30% off first ride" offer while the
    // server took 30% capped at GHS 40, so above GHS 133.33 the number agreed on
    // this screen was lower than the number billed. The offer is withdrawn, and
    // with it the only place in the app where the two could disagree.
    final fare = full?.fareGhs;
    return Scaffold(
      // Opaque white. A scrim over the map is what this page used to be, and a
      // rider confirming where they are going should be able to see it.
      backgroundColor: MngColors.page,
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
        title: const Text('Confirm your ride'),
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 20.h),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StopField(
                  fieldName: 'pickup',
                  fieldKey: const Key('pickupField'),
                  icon: Icons.circle,
                  iconColor: MngColors.success,
                  stop: _pickup,
                  hint: 'Where should we pick you up?',
                  active: _editing == _Field.pickup,
                  onChanged: (v) => _onQueryChanged(_Field.pickup, v),
                  onTap: () => _focus(_Field.pickup),
                  onPickOnMap: _pickingOnMap && _mapField == _Field.pickup
                      ? () => setState(() => _pickingOnMap = false)
                      : () => _openMapFor(_Field.pickup),
                  showMapAction: true,
                ),
                SizedBox(height: 8.h),
                _StopField(
                  fieldName: 'dropoff',
                  fieldKey: const Key('dropoffField'),
                  icon: Icons.circle,
                  iconColor: MngColors.error,
                  stop: _dropoff,
                  hint: 'Where are you going?',
                  active: _editing == _Field.dropoff,
                  onChanged: (v) => _onQueryChanged(_Field.dropoff, v),
                  onTap: () => _focus(_Field.dropoff),
                  onPickOnMap: _pickingOnMap && _mapField == _Field.dropoff
                      ? () => setState(() => _pickingOnMap = false)
                      : () => _openMapFor(_Field.dropoff),
                  showMapAction: true,
                ),
                // Save the destination, once there is one to save.
                //
                // After the dropoff field rather than the pickup: a rider
                // saving "Home" means where they are going home *to*, and putting
                // it beside the pickup invites saving the wrong end of the trip.
                if (widget.saved != null && _dropoff != null) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('savePlaceButton'),
                      onPressed: _savePlace,
                      icon: const Icon(Icons.bookmark_border, size: 18),
                      label: const Text('Save this place'),
                    ),
                  ),
                ],
                if (_editing != null) ...[
                  SizedBox(height: 8.h),
                  _Results(
                    results: _results,
                    searching: _searching,
                    query: _query,
                    onPick: (hit) => _choose(_editing ?? _Field.dropoff, hit),
                  ),
                ],
                if (_pickingOnMap) ...[
                  SizedBox(height: 10.h),
                  _MapPicker(
                    field: _mapField,
                    // The point the map is centred on. Null when the field being
                    // set is the destination and there is not one yet, in which
                    // case the map falls back to the pickup rather than inventing
                    // a centre: the rider can pan anywhere, and a map centred on
                    // a fabricated point is a map centred on a lie.
                    point: _mapField == _Field.pickup
                        ? _pickup.point
                        : _dropoff?.point ?? _pickup.point,
                    pickupLabel: _labelFor(
                      _mapField == _Field.pickup ? _pickup : _dropoff,
                    ),
                    dropoffLabel: _labelFor(_dropoff),
                    onPick: _pickOnMap,
                    onClose: () => setState(() => _pickingOnMap = false),
                  ),
                ],
                SizedBox(height: 12.h),
                // The fare and distance only exist once both ends are known. A
                // row reading "GHS 0.00" before a destination has been chosen is
                // a price, and a wrong one is worse than no price.
                if (_canSubmit)
                  Container(
                    padding: EdgeInsets.all(12.w),
                    decoration: BoxDecoration(
                      color: MngColors.muted,
                      borderRadius: BorderRadius.circular(MngRadius.small),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            // Safe: this block only draws when both ends exist.
                            '${_distanceKm!.toStringAsFixed(1)} km  ·  ~$_driveMinutes min drive',
                            overflow: TextOverflow.ellipsis,
                            style: MngTheme.light.textTheme.titleMedium,
                          ),
                        ),
                        SizedBox(width: 8.w),
                        Text(
                          'GHS ${fare!.toStringAsFixed(2)}',
                          style: MngTheme.light.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    key: const Key('noDestinationYet'),
                    padding: EdgeInsets.all(12.w),
                    decoration: BoxDecoration(
                      color: MngColors.muted,
                      borderRadius: BorderRadius.circular(MngRadius.small),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          size: 16,
                          color: MngColors.textSub,
                        ),
                        SizedBox(width: 8.w),
                        Expanded(
                          child: Text(
                            'Choose where you are going to see the fare.',
                            style: MngTheme.light.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_isUneditedDefault) ...[
                  SizedBox(height: 10.h),
                  Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        size: 16,
                        color: MngColors.textSub,
                      ),
                      SizedBox(width: 6.w),
                      Expanded(
                        child: Text(
                          'Still the demo route. Tap either field to pick '
                          'somewhere else.',
                          style: MngTheme.light.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
                SizedBox(height: 16.h),
                CategoryChips(
                  selected: _category,
                  onSelected: (c) => setState(() => _category = c),
                ),
                SizedBox(height: 14.h),
                SchedulePicker(
                  value: _scheduledFor,
                  onChanged: (v) => setState(() => _scheduledFor = v),
                ),
                SizedBox(height: 20.h),
                FilledButton(
                  key: const Key('confirmRouteButton'),
                  onPressed: _canSubmit ? _submit : null,
                  // The label says what the button will do, which is the only
                  // thing that keeps a scheduled booking from reading as an
                  // immediate one. "Search for a ride" on a ride for tomorrow
                  // morning is a lie the rider believes until the car does not
                  // come.
                  child: Text(
                    _scheduledFor == null
                        ? 'Search for a ride'
                        : 'Book for ${formatScheduledMoment(_scheduledFor!)}',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _focus(_Field field) {
    if (_editing == field) return;
    setState(() {
      _editing = field;
      _query = '';
      _results = const [];
    });
  }
}

enum _Field { pickup, dropoff }

/// The map the rider picks a point on, inside the sheet.
///
/// A small map rather than a full-screen one, and this is a deliberate limit
/// rather than a first version: the sheet is already the place the two stops
/// and the fare live, and a rider comparing a map to a fare needs both on
/// screen at once. The cost is that the map is small enough that a precise
/// doorway needs the search field instead, which is why the field is still
/// there and the map is an addition rather than a replacement.
///
/// The pin moves to the tapped point, and the field above updates. The tapped
/// point is not reverse-geocoded here: the sheet's state does that, so a late
/// answer can be discarded rather than landing on whichever field the rider has
/// since moved on to.
class _MapPicker extends StatelessWidget {
  const _MapPicker({
    required this.field,
    required this.point,
    this.pickupLabel,
    this.dropoffLabel,
    required this.onPick,
    required this.onClose,
  });

  final _Field field;

  /// The names to print on the pins, passed in rather than read from the stops.
  ///
  /// This widget is handed a point and nothing else -- it does not know about
  /// the trip -- so the names have to arrive with it. A map picker that reached
  /// back into the page for them would couple a dialog to the screen behind it.
  final String? pickupLabel;
  final String? dropoffLabel;

  /// The point the map is centred on. Never null: see the call site.
  final GeoPoint point;
  final ValueChanged<GeoPoint> onPick;
  final VoidCallback onClose;

  /// Tall enough to pan with a thumb and to see a few blocks, short enough
  /// that the two stop fields and the fare stay on screen above it.
  static const double height = 220;

  @override
  Widget build(BuildContext context) {
    final what = field == _Field.pickup ? 'pickup' : 'drop-off';
    return Column(
      key: const Key('mapPicker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(MngRadius.small),
          child: SizedBox(
            height: height,
            // Interactive and tappable, for the same reason the finding screen's
            // map is: the gestures are only useful if a tap can also mean
            // something, and with `onTapPoint` unset a tap would do nothing at
            // all while the map pretended to be fully controllable.
            child: RideMap(
              key: const Key('pickerMap'),
              pickup: point,
              // Named, because the rider is standing at a spot choosing it and
              // an unlabelled dot is a dot they have to recognise. The name
              // follows the field above it, so a stop that is still reading
              // "Picked on the map" says exactly that on the pin -- honest
              // about not having been geocoded rather than blank.
              pickupLabel: pickupLabel,
              dropoffLabel: dropoffLabel,
              interactive: true,
              onTapPoint: onPick,
              fill: true,
            ),
          ),
        ),
        SizedBox(height: 6.h),
        Row(
          children: [
            Expanded(
              child: Text(
                'Tap the map to move your $what point.',
                style: MngTheme.light.textTheme.bodySmall,
              ),
            ),
            TextButton(
              key: const Key('closeMapPicker'),
              onPressed: onClose,
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    );
  }
}

/// One editable stop: a dot, the current value, and a text field over the top.
///
/// The field is always present rather than swapping in on focus, so the value
/// the rider sees and the value they are editing are never two different
/// widgets, and so a test can find it without simulating a focus change first.
class _StopField extends StatelessWidget {
  const _StopField({
    required this.fieldName,
    required this.fieldKey,
    required this.icon,
    required this.iconColor,
    required this.stop,
    required this.hint,
    required this.active,
    required this.onChanged,
    required this.onTap,
    this.onPickOnMap,
    this.showMapAction = false,
  });

  /// A name for this field, used to build [fieldKey] and the map button's key.
  ///
  /// A name rather than interpolating [fieldKey] into the button's key: a `Key`
  /// stringifies to `Key("pickupField")`, so the button would have been keyed
  /// `mapAction-Key("pickupField")` and found by nobody.
  final String fieldName;

  final Key fieldKey;
  final IconData icon;
  final Color iconColor;

  /// The stop this field is showing, or null when there is not one yet.
  ///
  /// Null rather than a `TripStop` with an empty address over some placeholder
  /// coordinate. A blank stop is a real state -- the rider has not chosen a
  /// destination -- and inventing a point for it would put a pin in the Gulf of
  /// Guinea the moment anything downstream read it.
  final TripStop? stop;
  final String hint;
  final bool active;
  final ValueChanged<String> onChanged;
  final VoidCallback onTap;

  /// Opens, or closes, the map picker for this field.
  final VoidCallback? onPickOnMap;

  /// Whether to draw the map button at all.
  final bool showMapAction;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 4.h),
        decoration: BoxDecoration(
          color: active ? MngColors.muted : MngColors.page,
          borderRadius: BorderRadius.circular(MngRadius.small),
          border: active
              ? Border.all(color: MngColors.primary, width: 1.5)
              : null,
        ),
        child: Row(
          children: [
            Icon(icon, size: 10, color: iconColor),
            SizedBox(width: 10.w),
            Expanded(
              child: TextField(
                key: fieldKey,
                controller: TextEditingController(text: stop?.address ?? '')
                  ..selection = TextSelection.collapsed(
                    offset: stop?.address.length ?? 0,
                  ),
                onTap: onTap,
                onChanged: onChanged,
                style: MngTheme.light.textTheme.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: hint,
                  hintStyle: MngTheme.light.textTheme.bodyMedium?.copyWith(
                    color: MngColors.textSub,
                  ),
                ),
              ),
            ),
            if (showMapAction && onPickOnMap != null)
              IconButton(
                key: Key('mapAction-$fieldName'),
                // Its own label, because the icon alone is ambiguous next to a
                // text field: this sits inside the field, so a screen reader
                // announcing "button" next to "Where should we pick you up?"
                // would give a rider no idea what the button does.
                tooltip: 'Choose on the map',
                icon: const Icon(Icons.map_outlined, size: 18),
                color: MngColors.textSub,
                onPressed: onPickOnMap,
              ),
          ],
        ),
      ),
    );
  }
}

/// The list of matches, or the honest reason there are none.
class _Results extends StatelessWidget {
  const _Results({
    required this.results,
    required this.searching,
    required this.query,
    required this.onPick,
  });

  final List<PlaceSuggestion> results;
  final bool searching;
  final String query;
  final ValueChanged<PlaceSuggestion> onPick;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return Container(
        key: const Key('placeResults'),
        padding: EdgeInsets.all(12.w),
        decoration: BoxDecoration(
          color: MngColors.muted,
          borderRadius: BorderRadius.circular(MngRadius.small),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: searching
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : null,
            ),
            SizedBox(width: 10.w),
            Expanded(
              child: Text(
                searching
                    ? 'Looking for places...'
                    : query.trim().length < kMinPlaceSearchChars
                    ? 'Type at least $kMinPlaceSearchChars letters.'
                    : 'Nothing matched "$query".',
                style: MngTheme.light.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      key: const Key('placeResults'),
      decoration: BoxDecoration(
        color: MngColors.muted,
        borderRadius: BorderRadius.circular(MngRadius.small),
      ),
      child: Column(
        children: [
          for (final hit in results)
            InkWell(
              key: Key('placeHit-${hit.label}'),
              onTap: () => onPick(hit),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                child: Row(
                  children: [
                    const Icon(
                      Icons.place_outlined,
                      size: 16,
                      color: MngColors.textSub,
                    ),
                    SizedBox(width: 10.w),
                    Expanded(
                      child: Text(
                        hit.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: MngTheme.light.textTheme.bodyMedium,
                      ),
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
