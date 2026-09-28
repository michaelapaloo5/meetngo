import 'package:mng_core/mng_core.dart';

/// A trip row from the driver's own history, with the columns [Trip] does not
/// carry.
///
/// `Trip` in `mng_core` is the shared model both apps read out of a live trip
/// and out of an offer, and it has no `created_at`, no `started_at` and no
/// `completed_at`: the rider app has no use for them and a shared package
/// cannot grow a field for one consumer. A trip history without a date is not a
/// history -- "Completed" with no day against it is the same line every time --
/// so the two timestamps this app needs ride alongside the model rather than
/// being added to it.
///
/// Not a parallel model: the trip itself is still `mng_core`'s `Trip`, and this
/// is the same shape `earnings_repository.dart` uses for `LedgerEntry`.
class DriverTrip {
  const DriverTrip({
    required this.trip,
    required this.createdAt,
    this.startedAt,
    this.completedAt,
  });

  /// Reads one `trips` row.
  ///
  /// The four timestamps are all nullable in the database (`created_at` is not,
  /// and the rest are), and `DateTime.parse` on a null throws a `TypeError` --
  /// an `Error`, not an `Exception`, so it would slip past an
  /// `on DriverAuthFailure` and reach the framework as an unhandled async error
  /// with nothing on screen. A missing timestamp is therefore null here, not a
  /// crash.
  factory DriverTrip.fromRow(Map<String, dynamic> row) => DriverTrip(
        trip: Trip.fromJson(row),
        createdAt: DateTime.parse(row['created_at'] as String),
        startedAt: _date(row['started_at']),
        completedAt: _date(row['completed_at']),
      );

  final Trip trip;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;

  String get id => trip.id;

  /// The state as a driver would say it, not as the enum spells it.
  ///
  /// The enum names are the database's (`arriving`), and they are also the word
  /// a driver uses for something else entirely. A history row is not a state
  /// machine readout; it is a record of a journey, so it reads as one.
  String get stateLabel => switch (trip.state) {
        TripState.requested => 'Waiting for a match',
        TripState.matched => 'Assigned to you',
        TripState.arriving => 'Heading to the pickup',
        TripState.ongoing => 'Riding to the drop-off',
        TripState.completed => 'Completed',
        TripState.cancelled => 'Cancelled',
      };

  /// The day this trip happened, formatted for this app's audience.
  ///
  /// `dd MMM yyyy` and a 12-hour clock: this is read in Accra, where a 24-hour
  /// clock is not what anyone writes.
  String get dateLabel {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final at = completedAt ?? createdAt;
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final minute = at.minute.toString().padLeft(2, '0');
    final meridiem = at.hour < 12 ? 'am' : 'pm';
    return '${at.day} ${months[at.month - 1]} ${at.year}, $hour:$minute $meridiem';
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;
}
