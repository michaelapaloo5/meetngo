import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/place_service.dart';
import '../data/saved_place_repository.dart';

/// Where would you go, as a whole screen rather than a panel over one.
///
/// This replaces a modal bottom sheet, and the reason is worth stating
/// because the sheet was not a small version of this page — it was a
/// different, worse thing. It asked for two stops and a tier and a fare in one
/// scrimmed panel, which is the entire booking decision compressed into
/// something a rider cannot see all of at once, over a map they cannot move.
/// On top of that it covered the map it was describing, and a rider who
/// wanted to check where the pickup actually was had to dismiss the thing
/// that told them.
///
/// What replaced it is the two steps every ride-hailing app uses, and the
/// first one is this: type, and read a list. Nothing else is on the screen, so
/// the list is the screen. A rider who knows "Spintex" types six letters and
/// taps it, and never has to think about a pickup they did not come to choose.
///
/// Full screen is also what makes the list usable. The sheet's results were a
/// dropdown under two text fields, so every match was competing for the same
/// few hundred pixels with a fare and two categories; here each match gets a
/// full-width row and the whole list scrolls.
class DestinationSearchPage extends StatefulWidget {
  const DestinationSearchPage({
    super.key,
    required this.places,
    this.recent = const [],
    this.initialQuery = '',
    this.saved,
  });

  /// The geocoder, injected so the page has no network of its own and a test
  /// can drive it from a list.
  final PlaceService places;

  /// The rider's own recent destinations, shown before anything is typed.
  ///
  /// Real trips from `trips`, deduplicated. The alternative -- an empty screen
  /// with a cursor in it -- is what a first-time rider sees on the most
  /// important screen in the app, and an invented "popular destinations" list
  /// would be a lie in a different way: places nobody in this pilot has ever
  /// ridden to.
  final List<PlaceSuggestion> recent;

  /// Pre-fills the field, so coming back from editing a destination does not
  /// clear what the rider had typed.
  final String initialQuery;

  /// Where the rider's saved places come from, or null for nowhere.
  ///
  /// Null hides the section rather than showing an empty heading, for the reason
  /// every optional thing in this app does: a section titled "Saved places" over
  /// nothing is a promise the app cannot keep, and a rider who has never saved
  /// one should not be shown a place to put it.
  final SavedPlaceRepository? saved;

  @override
  State<DestinationSearchPage> createState() => _DestinationSearchPageState();
}

class _DestinationSearchPageState extends State<DestinationSearchPage> {
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );

  /// Focused on open, always.
  ///
  /// A rider arrived here by tapping a field that says "where would you go?".
  /// Making them tap again is a second tap for the same request, and on a
  /// keyboard-first screen the keyboard *is* the interface -- if it is not up,
  /// the page is a list with no way to fill it.
  late final FocusNode _focus = FocusNode();

  List<PlaceSuggestion> _results = const [];
  bool _searching = false;

  /// Set when the last search returned nothing, so the message can say what
  /// was searched for rather than showing a bare "No results".
  String? _searchedFor;

  Timer? _debounce;

  /// Long enough to be a pause in typing, short enough that the list feels
  /// attached to the keyboard.
  ///
  /// Nominatim's usage policy caps this service at one request a second and
  /// treats autocomplete traffic as unacceptable. One request per pause is the
  /// difference between that and a policy violation.
  static const Duration _searchDelay = Duration(milliseconds: 450);

  @override
  void initState() {
    super.initState();
    unawaited(_raiseKeyboard());
    unawaited(_loadSaved());
  }

  /// Focuses the field and brings the keyboard up.
  ///
  /// `requestFocus` alone was not enough, and this is a bug only a device
  /// finds. On an Android 16 handset the page opened with the field visibly
  /// focused -- the highlight ring was drawn -- while `dumpsys input_method`
  /// reported `mInputShown=false`, and the keyboard only appeared on a second
  /// tap. A field that takes focus in the same frame its route finishes being
  /// pushed does not reliably bring the IME up with it, because the window has
  /// not finished acquiring input focus at that point.
  ///
  /// So: wait for the frame to end, focus, and then ask the engine for the
  /// keyboard directly. The explicit request is the part that fixes it; the
  /// delay alone does not, and focus alone does not.
  ///
  /// A missing IME is not an error. The field is still focused either way, so
  /// the rider can tap it, and a tablet with no keyboard attached would
  /// otherwise have nothing to report.
  Future<void> _raiseKeyboard() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _focus.requestFocus();
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } on MissingPluginException {
      // No engine or no IME on this device. The field is focused, which is all
      // the page can promise.
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final trimmed = value.trim();
    // Rebuilt on every keystroke, not only on the short-query path.
    //
    // It used to `setState` only when the query was too short to search, and
    // rely on `_runSearch` to rebuild once the answer landed. That left up to
    // 450ms -- the debounce -- where the screen still showed the pre-typing
    // state: the saved-places row stayed up while the rider typed a real query,
    // and the heading still said "Where are you going?". A rider watching
    // letters appear in a field with no reaction underneath has typed into a
    // field they now suspect is broken.
    //
    // `_searching` is deliberately *not* set here. It is set when the request
    // goes out, because a spinner that appears and disappears per character
    // flickers and says nothing.
    setState(() {
      if (trimmed.length < kMinPlaceSearchChars) {
        _results = const [];
        _searching = false;
        _searchedFor = null;
      }
    });
    if (trimmed.length < kMinPlaceSearchChars) return;
    _debounce = Timer(_searchDelay, () => _runSearch(trimmed));
  }

  Future<void> _runSearch(String value) async {
    final token = ++_searchToken;
    setState(() => _searching = true);
    final found = await widget.places.search(value);
    if (!mounted || token != _searchToken) return;
    setState(() {
      _results = found;
      _searching = false;
      _searchedFor = value;
    });
  }

  int _searchToken = 0;

  /// The rider's saved places, or empty when there are none or nowhere to get
  /// them from.
  ///
  /// A failed load leaves this empty and the section hidden, rather than an error
  /// on the most important screen in the app. The rider can still type a place,
  /// which is this page's actual job; saved places are a convenience on top of
  /// search, and search does not need them.
  List<SavedPlace> _saved = const [];

  /// Reads the rider's saved places off the database.
  ///
  /// Started from `initState` alongside the keyboard rather than waited for:
  /// this screen's job is search, and a rider who has to wait for a list of
  /// their own places before they can type is a rider who types first and sees
  /// the chips arrive underneath.
  Future<void> _loadSaved() async {
    final repository = widget.saved;
    if (repository == null) return;
    // Caught here rather than trusted to the repository.
    //
    // `SupabaseSavedPlaceRepository.all` does swallow its own errors, and this
    // page was written assuming that. So the page had no `try` at all, which
    // means it worked only as long as that one implementation did -- and the day
    // someone wrote a second implementation, or the read started failing for a
    // reason the repository does not recognise, the throw would escape
    // `initState` and take the most important screen in the app with it.
    //
    // The outcome is the same either way: no row, and search still works.
    List<SavedPlace> found;
    try {
      found = await repository.all();
    } on Object {
      return;
    }
    if (!mounted) return;
    // Unroutable rows are dropped rather than offered: a place with no readable
    // coordinate is a row nobody can send a car to, and a tap that selects it
    // books nothing.
    setState(() {
      _saved = found.where((p) => p.isRoutable).toList();
    });
  }

  /// Picks a saved place as the destination.
  ///
  /// Converted to a `PlaceSuggestion` rather than popped as a different type,
  /// because the caller of this page is waiting for a `PlaceSuggestion` and
  /// having two return shapes would mean a branch at every call site for one
  /// kind of choice.
  void _pickSaved(SavedPlace place) {
    _focus.unfocus();
    Navigator.of(context).pop(
      PlaceSuggestion(
        // The **address**, not the label the rider gave it.
        //
        // "Home" is what the rider calls it; it is not a place, and the confirm
        // screen prints this string as the destination on the map pin, on the
        // trip row and on the receipt. A rider who booked to "Home" and then saw
        // "Home" on a map in Dansoman would have no way to check it. The label
        // stays as the chip's own text, where it belongs.
        label: place.address.trim().isNotEmpty ? place.address : place.label,
        point: place.point,
      ),
    );
  }

  /// Removes a saved place and drops it from the list whether or not the write
  /// lands.
  ///
  /// Removing it from the screen either way, because the alternative is a row
  /// that stays until the page is reopened and looks like the delete failed.
  /// `remove` swallows its own errors, so a row that was never deleted comes
  /// back on the next open, which is recoverable; a row that never disappears is
  /// not.
  Future<void> _removeSaved(SavedPlace place) async {
    setState(() {
      _saved = _saved.where((p) => p.id != place.id).toList();
    });
    try {
      await widget.saved?.remove(place.id);
    } on Object {
      // Swallowed on purpose, and the row stays gone either way. A throw here
      // escapes an `onPressed` callback with nobody to catch it, so the rider
      // would get an unhandled error from tapping an X rather than a chip that
      // stopped being there. The place comes back on the next open if the write
      // really failed, which is a thing they can see and act on.
    }
  }

  /// Whether the saved section should be on screen.
  ///
  /// Only while the field is empty. Once a rider starts typing, the list they
  /// are reading has to be results -- a "Saved places" block sitting above the
  /// matches for what they typed is noise, and the matches are the answer.
  bool get _showSaved =>
      widget.saved != null && _saved.isNotEmpty && _query.text.trim().isEmpty;

  void _pick(PlaceSuggestion hit) {
    // Dismiss the keyboard before the page goes away, or it lingers over the
    // page underneath for the length of that transition.
    _focus.unfocus();
    Navigator.of(context).pop(hit);
  }

  void _clear() {
    _debounce?.cancel();
    _query.clear();
    setState(() {
      _results = const [];
      _searching = false;
      _searchedFor = null;
    });
    _focus.requestFocus();
  }

  /// What the list is showing right now, and why.
  ({List<PlaceSuggestion> items, String heading}) get _list {
    if (_results.isNotEmpty) {
      return (
        items: _results,
        heading: '${_results.length} match${_results.length == 1 ? '' : 'es'}',
      );
    }
    if (_searchedFor != null) {
      // Nothing matched. The query is repeated because "no results" with no
      // query attached reads as a broken search rather than a wrong one.
      return (items: const [], heading: 'Nothing matched "$_searchedFor"');
    }
    if (_query.text.trim().length == 1) {
      return (items: const [], heading: 'Keep typing to search');
    }
    if (_query.text.trim().length >= 2) {
      return (
        items: const [],
        heading: 'Type at least $kMinPlaceSearchChars letters to search',
      );
    }
    if (widget.recent.isEmpty) {
      return (items: const [], heading: 'Where are you going?');
    }
    return (items: widget.recent, heading: 'Recent destinations');
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      // Opaque white, not a scrim over the map. The rider came here to read a
      // list, and a list over a moving map is a list they have to fight.
      backgroundColor: MngColors.page,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SearchBar(
              controller: _query,
              focusNode: _focus,
              onChanged: _onChanged,
              onClear: _clear,
              onBack: () => Navigator.of(context).maybePop(),
            ),
            if (_showSaved) ...[
              // A horizontal row rather than a block above the list.
              //
              // Saved places are two or three words -- Home, Work, Airport -- and
              // they belong where they cannot take a row from a search result. A
              // vertical block would push the matches down and, worse, would need
              // a second scroll view: a rider with nine saved places scrolling
              // past them would scroll the results underneath at the same time.
              // This row scrolls on its own axis and costs the results nothing.
              SizedBox(
                height: 48.h,
                child: ListView.separated(
                  key: const Key('savedPlacesRow'),
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: 20.w),
                  itemCount: _saved.length,
                  separatorBuilder: (_, _) => SizedBox(width: 8.w),
                  itemBuilder: (_, i) {
                    final place = _saved[i];
                    return _SavedPlaceChip(
                      place: place,
                      onPick: () => _pickSaved(place),
                      onRemove: () => _removeSaved(place),
                    );
                  },
                ),
              ),
            ],
            Expanded(
              child: _DestinationList(
                items: list.items,
                heading: list.heading,
                searching: _searching,
                onPick: _pick,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One saved place, as a chip, with a way to remove it.
///
/// Removal is a separate small target rather than a long-press: long-press is
/// undiscoverable, and a rider who wants a place gone has no reason to know
/// they are supposed to hold the chip down first. Deleting somebody's "Home"
/// by accident is also worse than an extra 24 pixels, so the two are not the
/// same gesture.
class _SavedPlaceChip extends StatelessWidget {
  const _SavedPlaceChip({
    required this.place,
    required this.onPick,
    required this.onRemove,
  });

  final SavedPlace place;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return InputChip(
      key: Key('savedPlace-${place.id}'),
      label: Text(place.label),
      onPressed: onPick,
      onDeleted: onRemove,
      deleteIcon: const Icon(Icons.close, size: 16),
      deleteButtonTooltipMessage: 'Remove ${place.label}',
      // A chip's label is one line and the address is not shown: these are two or
      // three words, and the full address belongs in the confirm screen where the
      // rider is about to agree to it.
      tooltip: place.address.trim().isEmpty ? place.label : place.address,
    );
  }
}

/// The back arrow and the field, on one row.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
    required this.onBack,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8.w, 8.h, 16.w, 8.h),
      child: Row(
        children: [
          IconButton(
            key: const Key('destinationBack'),
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: onBack,
          ),
          Expanded(
            child: TextField(
              key: const Key('destinationSearchField'),
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: MngTheme.light.textTheme.titleMedium,
              decoration: InputDecoration(
                hintText: 'Where to?',
                hintStyle: MngTheme.light.textTheme.titleMedium?.copyWith(
                  color: MngColors.textSub,
                ),
                prefixIcon: const Icon(Icons.search, color: MngColors.textSub),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (_, value, _) => value.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          key: const Key('clearDestinationSearch'),
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: 'Clear',
                          onPressed: onClear,
                        ),
                ),
                filled: true,
                fillColor: MngColors.muted,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(MngRadius.small),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The results, or the honest reason there are none.
class _DestinationList extends StatelessWidget {
  const _DestinationList({
    required this.items,
    required this.heading,
    required this.searching,
    required this.onPick,
  });

  final List<PlaceSuggestion> items;
  final String heading;
  final bool searching;
  final ValueChanged<PlaceSuggestion> onPick;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Empty(heading: heading, searching: searching);
    }
    return ListView.separated(
      key: const Key('destinationResults'),
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 24.h),
      itemCount: items.length + 1,
      separatorBuilder: (_, _) =>
          Divider(height: 1.h, color: MngColors.divider),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: EdgeInsets.only(bottom: 8.h, top: 4.h),
            child: Text(heading, style: MngTheme.light.textTheme.bodySmall),
          );
        }
        final hit = items[i - 1];
        return ListTile(
          key: Key('destinationHit-${hit.label}'),
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            heading == 'Recent destinations'
                ? Icons.history
                : Icons.place_outlined,
            color: MngColors.textSub,
          ),
          title: Text(
            hit.label,
            style: MngTheme.light.textTheme.bodyMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(
            Icons.north_west,
            size: 16,
            color: MngColors.textSub,
          ),
          onTap: () => onPick(hit),
        );
      },
    );
  }
}

/// Nothing to show, and the reason, with a spinner while one is coming.
class _Empty extends StatelessWidget {
  const _Empty({required this.heading, required this.searching});

  final String heading;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24.w),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (searching) ...[
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(height: 16.h),
          ] else
            const Icon(Icons.search, size: 32, color: MngColors.textSub),
          SizedBox(height: 12.h),
          Text(
            heading,
            key: const Key('destinationEmpty'),
            textAlign: TextAlign.center,
            style: MngTheme.light.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
