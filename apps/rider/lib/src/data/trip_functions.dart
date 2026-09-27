import 'package:supabase_flutter/supabase_flutter.dart';

import 'function_failure.dart';
import 'trip_repository.dart';

/// The Edge Function calls a trip's settlement and its demo payment need,
/// behind a port.
///
/// `TripController` is a state machine over a `TripRepository` and holds no
/// Supabase client, the same way `TrackingController` holds none: a controller
/// that reached for `Supabase.instance` itself could not be driven by a fake at
/// all, and the two functions below are the only things in this task that talk
/// to a server. `SupabaseTripFunctions` is the real implementation, and the
/// rider app passes one in at the point Task 16 wires the screens up.
///
/// The name is part of the contract, not decoration: `functions.invoke`
/// **throws** on any status outside 200..299
/// (`functions_client-2.7.1/lib/src/functions_client.dart:255-269`) and its
/// `FunctionResponse` carries only `data` and `status` -- there is no `error`
/// field to read off a failure, so every failure arrives as a thrown
/// `FunctionException` and is turned into a `TripRequestFailure` carrying the
/// message `describeFunctionFailure` derived. A caller that expected
/// `res.error` here would read a null on every failure and report nothing.
abstract class TripFunctions {
  Future<Map<String, dynamic>> invoke(String name, Map<String, dynamic> body);
}

class SupabaseTripFunctions implements TripFunctions {
  SupabaseTripFunctions(this._client);

  final SupabaseClient _client;

  @override
  Future<Map<String, dynamic>> invoke(String name, Map<String, dynamic> body) async {
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(name, body: body);
    } on FunctionException catch (e) {
      throw TripRequestFailure(describeFunctionFailure(e));
    }
    final data = response.data;
    if (data is! Map) {
      // Same message and the same failure as `requestRide`
      // (`supabase_trip_repository.dart:78-80`): a 2xx whose body is not a JSON
      // object is a function that answered something this client cannot read,
      // and reporting it as nothing would leave the caller with a silent no-op.
      throw const TripRequestFailure('The trip service returned nothing');
    }
    return data.cast<String, dynamic>();
  }
}
