import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

import 'package:meetngo_rider/src/data/saved_place_repository.dart';

/// A stand-in for the Supabase client that records the calls made against it.
///
/// This exists rather than a fake repository because the bug it guards is
/// entirely about *which* call is made. `save` once used
/// `upsert(..., onConflict: 'rider_id')`; `rider_id` is not a unique column, so
/// PostgREST rejected every save and the repository returned null. Nothing
/// upstream could see that -- the sheet closed, no error was shown, and no
/// `saved_places` row existed. A test with a fake repository would have passed
/// throughout.
///
/// The chain is deliberately loose: the repository holds the client as `dynamic`
/// and Supabase's builders are awaitable, so the fake only has to be honest
/// about the method names and to return rows.
class _FakeClient {
  _FakeClient({this.userId = 'rider-1'});

  final String? userId;

  /// Every call, as `method`, in order.
  final List<String> calls = <String>[];

  /// Every `onConflict` argument passed, so a bogus one can be caught.
  final List<String?> conflictTargets = <String?>[];

  /// Thrown by the next `insert`, to model the unique index refusing.
  Object? failNextInsert;

  /// What the last insert/update was asked to write.
  Map<String, dynamic>? written;

  /// Rows the fake answers with.
  List<Map<String, dynamic>> selectAnswer = [
    {
      'id': 'row-1',
      'label': 'Home',
      'address': 'Spintex Road, Accra',
      'point': {'lat': 5.56, 'lng': -0.19},
    },
  ];

  /// Rows an `ilike` lookup answers with, used to find an existing place.
  List<Map<String, dynamic>> lookupAnswer = const [];

  Object? get auth => _Auth(userId);

  dynamic from(String table) => _Builder(this);
}

class _Auth {
  _Auth(this.id);
  final String? id;
  Object? get currentUser => id == null ? null : _User(id!);
}

class _User {
  _User(this.id);
  final String id;
}

/// A stand-in for a PostgREST builder.
///
/// `PostgrestBuilder<T, S, R> implements Future<T>` in postgrest 2.9.1, and that
/// is the whole reason `await query` works in `SupabaseTripRepository`. A fake
/// that is merely "awaitable by having a `then`" is **not** enough: `await` on a
/// statically-typed non-Future hands the value straight back, so the repository
/// got the builder instead of rows, `rows.map` threw a TypeError, and its own
/// `catch` swallowed it. Every read came back empty and every save null --
/// indistinguishable from the bug being tested.
///
/// So this implements [Future] the way the real thing does.
class _Builder implements Future<List<Map<String, dynamic>>> {
  _Builder(this._client);

  final _FakeClient _client;

  /// The operation this chain performs when awaited.
  ///
  /// Tracked on the builder rather than read off `_client.calls.last`, because a
  /// chain is `insert().select()` and the *last* call is the select. Reading the
  /// last call meant the simulated unique-index failure never fired, and two
  /// tests passed for a reason that had nothing to do with the code.
  String? _op;
  bool _lookedUp = false;

  _Builder _note(String method, {String? conflict}) {
    _client.calls.add(method);
    _client.conflictTargets.add(conflict);
    return this;
  }

  dynamic select([String? columns]) => _note('select');

  dynamic insert(Map<String, dynamic> row) {
    _client.written = row;
    _op = 'insert';
    return _note('insert');
  }

  dynamic upsert(Map<String, dynamic> row, {String? onConflict}) {
    _client.written = row;
    _op = 'upsert';
    return _note('upsert', conflict: onConflict);
  }

  dynamic update(Map<String, dynamic> row) {
    _client.written = row;
    _op = 'update';
    return _note('update');
  }

  dynamic delete() {
    _op = 'delete';
    return _note('delete');
  }

  dynamic eq(String column, Object value) => this;

  dynamic ilike(String column, Object value) {
    _lookedUp = true;
    return _note('ilike');
  }

  dynamic limit(int n) => this;
  dynamic order(String column, {bool ascending = true}) => this;

  /// The rows this chain resolves to, or the error it resolves with.
  Future<List<Map<String, dynamic>>> _resolve() async {
    if (_op == 'insert') {
      final fail = _client.failNextInsert;
      if (fail != null) {
        _client.failNextInsert = null;
        throw fail;
      }
    }
    if (_lookedUp) return _client.lookupAnswer;
    if (_op == 'delete') return const [];
    if (_op == 'update') {
      // PostgREST's `update(...).select()` answers with the row as it now
      // stands, so the fake has to do the same or the caller is handed the
      // pre-update row and the test is asserting on the fake rather than the
      // code.
      final written = _client.written ?? const <String, dynamic>{};
      return [
        {..._client.selectAnswer.first, ...written},
      ];
    }
    return _client.selectAnswer;
  }

  @override
  Future<R> then<R>(
    FutureOr<R> Function(List<Map<String, dynamic>>) onValue, {
    Function? onError,
  }) => _resolve().then(onValue, onError: onError);

  @override
  Future<List<Map<String, dynamic>>> catchError(
    Function onError, {
    bool Function(Object error)? test,
  }) => _resolve().catchError(onError, test: test);

  @override
  Future<List<Map<String, dynamic>>> whenComplete(
    FutureOr<void> Function() action,
  ) => _resolve().whenComplete(action);

  @override
  Stream<List<Map<String, dynamic>>> asStream() => _resolve().asStream();

  @override
  Future<List<Map<String, dynamic>>> timeout(
    Duration timeLimit, {
    FutureOr<List<Map<String, dynamic>>> Function()? onTimeout,
  }) => _resolve().timeout(timeLimit, onTimeout: onTimeout);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const place = SavedPlace(
  id: '',
  label: 'Home',
  address: 'Spintex Road, Accra',
  point: GeoPoint(5.56, -0.19),
);

void main() {
  group('save', () {
    test('inserts, and does not claim a conflict target that does not exist', () async {
      // The regression. `rider_id` is not unique -- the unique index is on
      // `(rider_id, lower(label))`, an expression PostgREST cannot be told
      // about -- so `onConflict: 'rider_id'` made every save fail and every save
      // silent.
      final client = _FakeClient();
      final saved = await SupabaseSavedPlaceRepository(client).save(place);

      expect(client.calls.first, 'insert');
      expect(
        client.conflictTargets,
        everyElement(isNull),
        reason:
            'an onConflict naming a non-unique column rejects the whole write',
      );
      expect(client.written!['label'], 'Home');
      expect(client.written!['address'], 'Spintex Road, Accra');
      expect(saved, isNotNull);
      expect(saved!.address, 'Spintex Road, Accra');
    });

    test('stores the point, or the place cannot be routed to', () async {
      // A saved place with no coordinate is a row nobody can send a car to, and
      // the whole feature is choosing one quickly.
      final client = _FakeClient();
      await SupabaseSavedPlaceRepository(client).save(place);
      final point = client.written!['point'] as Map;
      expect((point['lat'] as num).toDouble(), 5.56);
      expect((point['lng'] as num).toDouble(), -0.19);
    });

    test('writes nothing when the rider is signed out', () async {
      final client = _FakeClient(userId: null);
      final saved = await SupabaseSavedPlaceRepository(client).save(place);
      expect(saved, isNull);
      expect(client.calls, isEmpty, reason: 'no write against no rider');
    });

    test('writes nothing for a blank name', () async {
      // The column has `check (length(btrim(label)) > 0)`, so this would be
      // refused by the database anyway. Better to not send it.
      final client = _FakeClient();
      final saved = await SupabaseSavedPlaceRepository(client).save(
        const SavedPlace(
          id: '',
          label: '   ',
          address: 'x',
          point: GeoPoint(5.5, -0.2),
        ),
      );
      expect(saved, isNull);
      expect(client.calls, isEmpty);
    });

    test(
      'a refused insert updates the place already saved under that name',
      () async {
        // The unique index fires on "Home" then "home". Growing a second row would
        // leave the rider with two identical chips, which is what
        // `lower(label)` exists to prevent.
        final existing = <Map<String, dynamic>>[
          {
            'id': 'existing',
            'label': 'Home',
            'address': 'Spintex Road, Accra',
            'point': {'lat': 5.56, 'lng': -0.19},
          },
        ];
        final client = _FakeClient()
          ..failNextInsert = StateError(
            'duplicate key value violates unique index',
          )
          ..lookupAnswer = existing
          // The row the update targets, so the returned id is the one the rider
          // already had rather than the fake's default.
          ..selectAnswer = existing;
        final saved = await SupabaseSavedPlaceRepository(client).save(place);

        expect(saved, isNotNull);
        expect(saved!.id, 'existing', reason: 'the row they already had');
        expect(client.calls, contains('update'));
        expect(
          client.calls.where((c) => c == 'insert'),
          hasLength(1),
          reason: 'one attempt, not an insert and then an update',
        );
      },
    );

    test('a refused insert with nothing to find returns null rather than a row', () async {
      // The insert failed for some reason other than the duplicate, and there is
      // no existing place under that name. Returning null is what makes the
      // sheet say "could not save" rather than reporting a success that is not
      // one.
      final client = _FakeClient()
        ..failNextInsert = StateError('permission denied for table')
        ..lookupAnswer = const [];
      final saved = await SupabaseSavedPlaceRepository(client).save(place);
      expect(saved, isNull);
    });
  });

  group('all', () {
    test('drops a place whose point will not parse', () async {
      // `GeoPoint(0, 0)` is the sea off Ghana. A row that decodes to it is not
      // something to offer a rider as a destination.
      final client = _FakeClient()
        ..selectAnswer = [
          {
            'id': 'broken',
            'label': 'Broken',
            'address': 'Nowhere',
            'point': 'not a point',
          },
        ];
      final places = await SupabaseSavedPlaceRepository(client).all();
      expect(places, hasLength(1));
      expect(places.single.isRoutable, isFalse);
    });

    test('returns empty for a signed-out rider', () async {
      final client = _FakeClient(userId: null);
      expect(await SupabaseSavedPlaceRepository(client).all(), isEmpty);
    });
  });
}
