import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import 'earnings_controller.dart';

/// The mock MoMo prompt.
///
/// It asks for a 6-digit PIN and never uses it. A PIN box that is collected and
/// thrown away is the one control here a driver could mistake for a real
/// payment, so the copy above it says plainly that nothing is sent and that the
/// PIN is not checked against anything.
class PayoutSheet extends StatefulWidget {
  const PayoutSheet({super.key, required this.controller});

  final EarningsController controller;

  @override
  State<PayoutSheet> createState() => _PayoutSheetState();
}

class _PayoutSheetState extends State<PayoutSheet> {
  final _amount = TextEditingController();
  final _pin = TextEditingController();
  bool sent = false;

  @override
  void dispose() {
    _amount.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `ListenableBuilder` because the sheet holds the controller rather than
    // reading it from `context`, and a widget that reads a `ChangeNotifier` it
    // holds without listening to it cannot change. A refused withdrawal would
    // leave this sheet showing its empty form next to a balance the wallet
    // behind it has already changed, and the driver would see no reason at all.
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 32.h),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Withdraw to MoMo',
              style: MngTheme.light.textTheme.titleLarge,
            ),
            SizedBox(height: 6.h),
            Text(
              'Demo payout. No money moves, no network is called, and the PIN is '
              'not checked against anything.',
              style: MngTheme.light.textTheme.bodySmall,
            ),
            SizedBox(height: 20.h),
            TextField(
              key: const Key('payoutAmountField'),
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                prefixText: 'GHS ',
                hintText:
                    widget.controller.snapshot?.availableGhs.toStringAsFixed(
                      2,
                    ) ??
                    '0.00',
              ),
            ),
            SizedBox(height: 12.h),
            TextField(
              key: const Key('payoutPinField'),
              controller: _pin,
              obscureText: true,
              maxLength: 6,
              decoration: const InputDecoration(
                hintText: 'MoMo PIN (any 6 digits)',
                counterText: '',
              ),
            ),
            if (widget.controller.error != null) ...[
              SizedBox(height: 8.h),
              Text(
                widget.controller.error!,
                key: const Key('payoutError'),
                style: const TextStyle(color: MngColors.error),
              ),
            ],
            if (sent) ...[
              SizedBox(height: 16.h),
              Text(
                'Payout requested. It is a demo, so nothing was sent and your '
                'balance goes back up when you reload the wallet.',
                key: const Key('payoutSent'),
                style: const TextStyle(color: MngColors.success),
              ),
            ],
            SizedBox(height: 20.h),
            FilledButton(
              key: const Key('confirmPayoutButton'),
              onPressed: widget.controller.busy
                  ? null
                  : () async {
                      final ok = await widget.controller.requestPayout(
                        double.tryParse(_amount.text.trim()) ?? 0,
                      );
                      if (ok && mounted) setState(() => sent = true);
                    },
              child: const Text('Confirm withdrawal'),
            ),
          ],
        ),
      ),
    );
  }
}
