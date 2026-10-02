import 'package:mng_core/mng_core.dart';

/// A place the rider has saved, and the whole of what can be done with one.
///
/// Four operations and no more, because those four are the feature: list them,
/// add one, rename one, remove one. Everything else a rides app does with saved
/// places is a variation on one of those or a thing it invents.
abstract class SavedPlaceRepository {
  /// The rider's places, newest first.
  Future<List<SavedPlace>> all();

  /// Add [place], or return the one already saved under the same name.
  ///
  /// Upsert rather than insert-and-fail, because the database has a unique index
  /// on `(rider_id, lower(label))` and a plain insert would make saving "Home"
  /// twice a crash rather than a no-op.
  Future<SavedPlace?> save(SavedPlace place);

  /// Remove the place with [id].
  Future<void> remove(String id);
}

/// One saved place.
///
/// [label] is what the rider typed and [address] is whatever the geocoder said.
/// Both are real place names and neither may be a coordinate: `trip_copy.dart`
/// has a regex whose entire job is to stop a coordinate reaching a rider, and a
/// saved place is a string that sits in a list on the screen indefinitely.
class SavedPlace {
  const SavedPlace({
    required this.id,
    required this.label,
    required this.point,
    this.address = '',
  });

  factory SavedPlace.fromRow(Map<String, dynamic> row) {
    final raw = row['point'];
    final point = raw is Map
        ? GeoPoint(
            (raw['lat'] as num?)?.toDouble() ?? 0,
            (raw['lng'] as num?)?.toDouble() ?? 0,
          )
        // A malformed point is dropped rather than throwing. A saved place with
        // no usable coordinate is a list entry nobody can route to, which is a
        // nuisance; a crash on the destination screen is a dead app.
        : const GeoPoint(0, 0);
    return SavedPlace(
      id: row['id'] as String? ?? '',
      label: (row['label'] as String?) ?? '',
      address: (row['address'] as String?) ?? '',
      point: point,
    );
  }

  final String id;
  final String label;
  final String address;
  final GeoPoint point;

  /// Whether this place could actually be routed to.
  ///
  /// `GeoPoint(0, 0)` is the sea off Ghana, and it is what a row with an
  /// unreadable point decodes to -- see [SavedPlace.fromRow]. Rather than
  /// sending a rider there, the destination screen skips it.
  bool get isRoutable => !(point.lat == 0 && point.lng == 0);

  Map<String, dynamic> toRow() => {
    'label': label,
    'address': address,
    'point': point.toJson(),
  };
}

class SupabaseSavedPlaceRepository implements SavedPlaceRepository {
  SupabaseSavedPlaceRepository(this._client);

  final dynamic _client;

  @override
  Future<List<SavedPlace>> all() async {
    final user = _client.auth.currentUser;
    // Null rather than empty: a signed-out caller has no places, and asking the
    // database for another rider's would be refused anyway. RLS scopes this to
    // `rider_id = auth.uid()` regardless.
    if (user == null) return const [];
    try {
      final rows = await _client
          .from('saved_places')
          .select('id, label, address, point')
          .order('created_at', ascending: false)
          .limit(50);
      return (rows as List<dynamic>)
          .map((r) => SavedPlace.fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (_) {
      // A failed read leaves the list empty rather than taking the destination
      // screen down. The rider can still type a place; the screen's whole job is
      // search, and saved places are a convenience on top of it.
      return const [];
    }
  }

  @override
  Future<SavedPlace?> save(SavedPlace place) async {
    final user = _client.auth.currentUser;
    if (user == null) return null;
    if (place.label.trim().isEmpty) return null;
    final row = {'rider_id': user.id, ...place.toRow()};

    // A plain insert, then an update if it lost the race.
    //
    // This used to be `upsert(..., onConflict: 'rider_id')`. That does not work
    // and never has: the unique index is on `(rider_id, lower(label))`, an
    // expression, which PostgREST cannot be told about as a conflict target --
    // so `onConflict: 'rider_id'` named an index that does not exist, every save
    // errored, and the catch below returned whatever `_findByLabel` could find,
    // which after a failed insert is nothing.
    //
    // The result was the worst version of this bug: the button opened a dialog,
    // took the rider's name, and wrote nothing. Found by saving a place on the
    // handset and reading `saved_places` back with zero rows. The file's own
    // comment described the problem and then shipped the wrong answer to it.
    //
    // A plain insert is right anyway: it is one round trip in the ordinary case,
    // and the unique index does the duplicate detection for free.
    try {
      final rows = await _client
          .from('saved_places')
          .insert(row)
          .select('id, label, address, point');
      final first = (rows as List<dynamic>).firstOrNull;
      if (first == null) return null;
      return SavedPlace.fromRow(Map<String, dynamic>.from(first as Map));
    } on Object {
      // Already saved under this name -- either because the rider just did it,
      // or because they saved "Home" and are now saving "home". Update the row
      // they already have rather than growing a list of two identical entries,
      // which is what the `lower(label)` index exists to prevent.
      return await _updateExisting(place);
    }
  }

  /// Moves an already-saved place to [place]'s point, or returns null.
  Future<SavedPlace?> _updateExisting(SavedPlace place) async {
    final existing = await _findByLabel(place.label);
    if (existing == null || existing.id.isEmpty) return null;
    try {
      final rows = await _client
          .from('saved_places')
          .update(place.toRow())
          .eq('id', existing.id)
          .select('id, label, address, point');
      final first = (rows as List<dynamic>).firstOrNull;
      if (first == null) return null;
      return SavedPlace.fromRow(Map<String, dynamic>.from(first as Map));
    } on Object {
      // The row is the rider's own and the list reloads on the next open; a
      // failed update leaves the old point, which is recoverable.
      return null;
    }
  }

  Future<SavedPlace?> _findByLabel(String label) async {
    try {
      final rows = await _client
          .from('saved_places')
          .select('id, label, address, point')
          .ilike('label', label.trim())
          .limit(1);
      final first = (rows as List<dynamic>).firstOrNull;
      if (first == null) return null;
      return SavedPlace.fromRow(Map<String, dynamic>.from(first as Map));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(String id) async {
    if (id.isEmpty) return;
    try {
      await _client.from('saved_places').delete().eq('id', id);
    } catch (_) {
      // Nothing to say. The row is the rider's own and the list reloads on the
      // next open; a failed delete is at worst a place that reappears.
    }
  }
}
