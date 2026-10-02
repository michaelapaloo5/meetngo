import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

/// When a ride is wanted, rather than only now.
///
/// The default is [value] being null, which means *now*, and that is a real
/// choice rather than an absence: the majority of bookings are immediate and a
/// picker that opened on "in 30 minutes" would book the wrong time for all of
/// them.
///
/// ## Why suggestions and not a free date field
///
/// Four times and a custom choice. A rider who wants "half six" taps it; a rider
/// who wants something the app did not think of gets the custom option rather
/// than four wrong buttons and no way to say so. Nothing here is offered in a
/// place the rider cannot reach.
class SchedulePicker extends StatelessWidget {
  const SchedulePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.now,
  });

  /// The chosen moment, or null for "now".
  final DateTime? value;

  final ValueChanged<DateTime?> onChanged;

  /// What "now" means, injected so the suggestions are testable.
  ///
  /// Without this the picker can only be tested by freezing the clock, and a
  /// test that cannot control "now" ends up asserting on whatever day it runs.
  final DateTime? now;

  /// The four times offered, in the order offered.
  ///
  /// Rounded to the next quarter hour, because "in 15 minutes" for somebody
  /// standing on a street corner is a useful question and "in 17 minutes" is not.
  static List<({String label, Duration offset})> get options =>
      const <({String label, Duration offset})>[
        (label: 'Now', offset: Duration.zero),
        (label: 'In 30 min', offset: Duration(minutes: 30)),
        (label: 'In 1 hour', offset: Duration(hours: 1)),
        (label: 'Later today', offset: Duration(hours: 4)),
      ];

  /// The next quarter hour at or after [from].
  ///
  /// Ceiling rather than rounding, so a rider offered "in 30 minutes" gets at
  /// least 30 minutes. Rounding down would offer 12 minutes and call it 15.
  static DateTime quarterHourFrom(DateTime from) {
    final base = DateTime(
      from.year,
      from.month,
      from.day,
      from.hour,
      from.minute,
    );
    final remainder = base.minute % 15;
    return remainder == 0 ? base : base.add(Duration(minutes: 15 - remainder));
  }

  DateTime _now() => now ?? DateTime.now();

  /// The moment an offset lands on, snapped to the quarter hour.
  DateTime _at(Duration offset) => quarterHourFrom(_now().add(offset));

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    final chosen = value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('When', style: theme.titleMedium),
            const Spacer(),
            if (chosen != null)
              TextButton(
                key: const Key('scheduleClear'),
                onPressed: () => onChanged(null),
                child: const Text('Book now'),
              ),
          ],
        ),
        SizedBox(height: 6.h),
        Wrap(
          spacing: 8.w,
          runSpacing: 8.h,
          children: [
            for (final option in options)
              ChoiceChip(
                key: Key('scheduleChip-${option.offset.inMinutes}'),
                label: Text(
                  option.offset == Duration.zero
                      ? option.label
                      : '${option.label} · ${formatScheduledMoment(_at(option.offset))}',
                ),
                selected: _isSelected(option.offset, chosen),
                onSelected: (_) => onChanged(
                  option.offset == Duration.zero ? null : _at(option.offset),
                ),
              ),
            ActionChip(
              key: const Key('scheduleCustom'),
              avatar: const Icon(Icons.schedule, size: 18),
              label: const Text('Pick a time'),
              // Pressed, not selected: the custom option is a way to *choose*,
              // and a chip that stays highlighted afterwards would suggest it is
              // one of the fixed times.
              onPressed: () async {
                final picked = await _pickCustom(context);
                if (picked != null) onChanged(picked);
              },
            ),
          ],
        ),
      ],
    );
  }

  /// Whether [offset] is what [chosen] already holds.
  ///
  /// Compared on the snapped moment rather than on the raw offset, so a rider who
  /// picks 14:30 from the custom picker sees that chip lit rather than none of
  /// them.
  bool _isSelected(Duration offset, DateTime? chosen) {
    if (offset == Duration.zero) return chosen == null;
    if (chosen == null) return false;
    return _at(offset).isAtSameMomentAs(chosen);
  }

  Future<DateTime?> _pickCustom(BuildContext context) {
    final base = value ?? _now();
    final initial = DateTime(
      base.year,
      base.month,
      base.day,
      base.hour,
      base.minute,
    );
    return showDatePicker(
      context: context,
      initialDate: initial,
      // A ride for yesterday is not a thing anybody wants, and the database
      // would accept it and then never offer it.
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 90)),
    ).then((day) async {
      if (day == null || !context.mounted) return null;
      final picked = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(initial),
      );
      if (picked == null) return null;
      return DateTime(day.year, day.month, day.day, picked.hour, picked.minute);
    });
  }
}

/// A scheduled moment in words a rider can act on.
///
/// Deliberately never a bare date. "3 Oct" on a booking made on 2 Oct says
/// nothing about *when* on the 3rd, and a rider who has to work that out is the
/// rider who gets picked up at the wrong time.
///
/// Today and tomorrow are named rather than dated, because that is how people
/// refer to them; anything further out gets the date. Both paths print a clock
/// time, because the hour is the part people get wrong.
String formatScheduledMoment(DateTime when) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(when.year, when.month, when.day);
  final days = that.difference(today).inDays;
  final time = _clock(when);

  if (days == 0) return 'today, $time';
  if (days == 1) return 'tomorrow, $time';
  if (days == -1) return 'yesterday, $time';
  if (days > 1 && days < 7) return '$days days, $time';
  return '${when.day} ${_month(when.month)}, $time';
}

String _clock(DateTime when) {
  // 24-hour, because "18:30" is unambiguous and a rider reading "6:30" next to a
  // Ghanaian phone in 12-hour mode has to work out whether it is morning.
  final hour = when.hour.toString().padLeft(2, '0');
  final minute = when.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _month(int month) {
  const names = <String>[
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
  return month >= 1 && month <= 12 ? names[month - 1] : '?';
}
