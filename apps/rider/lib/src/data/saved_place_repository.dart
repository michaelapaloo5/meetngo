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
    try {
      final rows = await _client
          .from('saved_places')
          .upsert(
            {'rider_id': user.id, ...place.toRow()},
            // The unique index is on `(rider_id, lower(label))`, which is not a
            // column list, so it cannot be named as a conflict target. `onConflict`
            // is left to PostgREST's default of "the primary key", which would
            // insert a duplicate -- so the row is read back by label instead and
            // the insert is guarded by the index rejecting the duplicate.
            onConflict: 'rider_id',
          )
          .select('id, label, address, point');
      final first = (rows as List<dynamic>).firstOrNull;
      if (first == null) return null;
      return SavedPlace.fromRow(Map<String, dynamic>.from(first as Map));
    } catch (_) {
      // Saving the same place twice throws on the unique index. That is not a
      // failure worth showing a rider: the outcome they asked for -- that place
      // being saved -- is already true.
      return await _findByLabel(place.label);
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
