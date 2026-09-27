import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

/// The star row, the optional comment and the submit button, as a bottom sheet's
/// body. `ReceiptScreen` embeds it directly rather than in a sheet, so the same
/// widget is the rating affordance on a receipt and the rating affordance in a
/// sheet, and there is one set of keys for both.
class RatingSheet extends StatefulWidget {
  const RatingSheet({super.key, required this.onSubmit, this.headline});

  /// Called with the chosen stars and the comment. Only ever called on a submit
  /// with a selection: a rider who presses the button without choosing a star
  /// gets the prompt below and no call, so a caller cannot write a rating of 0
  /// by accident.
  final void Function(int stars, String comment) onSubmit;

  final String? headline;

  @override
  State<RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<RatingSheet> {
  int? _stars;
  bool _errorShown = false;
  final _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 20.h),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.headline ?? 'Rate your trip',
              style: MngTheme.light.textTheme.titleLarge),
          SizedBox(height: 16.h),
          Row(
            key: const Key('ratingStars'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Choosing a star clears the "pick a rating first" prompt rather
              // than leaving it under a selection that has been made, so the
              // prompt and the selection cannot disagree on screen.
              for (var i = 1; i <= 5; i++)
                GestureDetector(
                  key: Key('star-$i'),
                  onTap: () => setState(() {
                    _stars = i;
                    _errorShown = false;
                  }),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4.w),
                    child: Icon(
                      i <= (_stars ?? 0) ? Icons.star : Icons.star_border,
                      size: 36.w,
                      // Amber on white measures 1.85:1, which is why the
                      // unselected star is not amber: it is the whole affordance
                      // for "this one is not chosen yet" and it has to be visible
                      // on the page. `MngColors.textSub` clears 3:1 there, the
                      // floor WCAG 1.4.11 sets for a non-text graphic, and
                      // `test/trip/receipt_screen_test.dart` measures the ratio
                      // rather than quoting this comment.
                      color: i <= (_stars ?? 0)
                          ? MngColors.primary
                          : MngColors.textSub,
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: 16.h),
          TextField(
            key: const Key('ratingComment'),
            controller: _comment,
            maxLines: 2,
            decoration: const InputDecoration(hintText: 'Add a comment (optional)'),
          ),
          SizedBox(height: 16.h),
          if (_errorShown) ...[
            Text(
              'Pick a rating first',
              style: const TextStyle(color: MngColors.error),
            ),
            SizedBox(height: 8.h),
          ],
          FilledButton(
            key: const Key('submitRatingButton'),
            onPressed: () {
              if (_stars == null) {
                setState(() => _errorShown = true);
                return;
              }
              widget.onSubmit(_stars!, _comment.text);
            },
            child: const Text('Submit rating'),
          ),
        ],
      ),
    );
  }
}
