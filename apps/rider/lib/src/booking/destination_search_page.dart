import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/place_service.dart';

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
    if (trimmed.length < kMinPlaceSearchChars) {
      setState(() {
        _results = const [];
        _searching = false;
        _searchedFor = null;
      });
      return;
    }
    // "Searching" is set only once the request is actually going out, not on
    // the keystroke. A spinner that appears and disappears per character
    // flickers and says nothing.
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
      return (
        items: const [],
        heading: 'Keep typing to search',
      );
    }
    if (_query.text.trim().length >= 2) {
      return (
        items: const [],
        heading: 'Type at least $kMinPlaceSearchChars letters to search',
      );
    }
    if (widget.recent.isEmpty) {
      return (
        items: const [],
        heading: 'Where are you going?',
      );
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
                hintStyle: MngTheme.light.textTheme.titleMedium
                    ?.copyWith(color: MngColors.textSub),
                prefixIcon: const Icon(Icons.search, color: MngColors.textSub),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller, builder: (_, value, _) => value.text.isEmpty
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
      separatorBuilder: (_, _) => Divider(height: 1.h, color: MngColors.divider),
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
          trailing: const Icon(Icons.north_west,
              size: 16, color: MngColors.textSub),
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
