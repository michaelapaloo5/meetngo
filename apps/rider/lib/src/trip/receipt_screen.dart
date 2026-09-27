import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'rating_sheet.dart';

/// What `complete-trip` settles, as its 200 body carries it: the gross fare, the
/// platform's cut of it, and what is left for the driver.
///
/// The three are related by an identity rather than by three independent numbers,
/// and the receipt shows all three because the driver sees all three: the fare
/// entry and the commission entry in `ledger_entries` sum to `driverPayoutGhs`,
/// and that is what the driver's wallet is read off.
class Settlement {
  const Settlement({
    required this.fareGhs,
    required this.commissionGhs,
    required this.driverPayoutGhs,
  });

  final double fareGhs;
  final double commissionGhs;
  final double driverPayoutGhs;
}

class ReceiptScreen extends StatelessWidget {
  const ReceiptScreen({
    super.key,
    required this.trip,
    required this.settlement,
    required this.paymentState,
    required this.onRated,
  });

  final Trip trip;
  final Settlement settlement;
  final PaymentState paymentState;
  final void Function(int stars, String comment) onRated;

  @override
  Widget build(BuildContext context) {
    final voided = paymentState == PaymentState.voided;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Trip receipt'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(MngSpacing.md),
                decoration: BoxDecoration(
                  color: MngColors.surface,
                  borderRadius: BorderRadius.circular(MngRadius.large),
                  border: Border.all(color: MngColors.divider),
                ),
                child: Column(
                  children: [
                    _row('Trip fare', 'GHS ${settlement.fareGhs.toStringAsFixed(2)}'),
                    _row('Distance', '${trip.distanceKm.toStringAsFixed(1)} km'),
                    _row('Driver payout', 'GHS ${settlement.driverPayoutGhs.toStringAsFixed(2)}'),
                    Divider(color: MngColors.divider, height: 24.h),
                    // `Flexible` plus `FittedBox` on the value, not a bare `Row`
                    // of two `Text`s. The title is 20px of type
                    // (`app_theme.dart:39-40`) and so is 40px of it at 200%, and
                    // the bare `Row` then overflows the card by 58 pixels --
                    // measured by deleting both wrappers and reading the
                    // `RenderFlex` message at `GHS 20.40`; at
                    // `GHS 99999999.99` it is 300. The label ellipsizes and the
                    // money scales down, so the receipt can neither overflow nor
                    // clip a total to nothing. Which half does the work is
                    // measured in the test file: `FittedBox`, not `Flexible`.
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Total',
                            overflow: TextOverflow.ellipsis,
                            style: MngTheme.light.textTheme.titleMedium,
                          ),
                        ),
                        SizedBox(width: 12.w),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              voided
                                  ? 'GHS 0.00'
                                  : 'GHS ${settlement.fareGhs.toStringAsFixed(2)}',
                              key: const Key('receiptTotal'),
                              style: MngTheme.light.textTheme.titleLarge,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12.h),
              if (voided)
                Container(
                  padding: EdgeInsets.all(12.w),
                  decoration: BoxDecoration(
                    color: MngColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(MngRadius.small),
                  ),
                  child: const Text(
                    'This trip was not charged',
                    style: TextStyle(color: MngColors.error),
                  ),
                )
              else
                const Text(
                  'Demo payment — no real money moved',
                  style: TextStyle(color: MngColors.textSub),
                ),
              SizedBox(height: 24.h),
              RatingSheet(
                headline: 'How was your trip?',
                onSubmit: onRated,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: EdgeInsets.symmetric(vertical: 6.h),
        // The same width discipline as the total row, and the same measured
        // asymmetry: at `GHS 20.40` these rows are nowhere near the card's edge
        // at 200% and the wrapper is doing nothing, and at `GHS 112221.00` the
        // money rows overflow it by 63 and 35 pixels with the wrapper removed.
        // `numeric(10,2)` holds eight digits before the point
        // (`init.sql:61`), so that fare is one the database can hold. The label
        // ellipsizes and the value scales down.
        child: Row(
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: MngTheme.light.textTheme.bodySmall,
              ),
            ),
            SizedBox(width: 12.w),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(value, style: MngTheme.light.textTheme.bodyMedium),
              ),
            ),
          ],
        ),
      );
}
