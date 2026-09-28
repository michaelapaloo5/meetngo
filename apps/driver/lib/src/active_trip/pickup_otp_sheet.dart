import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import 'active_trip_controller.dart';

class PickupOtpSheet extends StatefulWidget {
  const PickupOtpSheet({super.key, required this.controller});

  final ActiveTripController controller;

  @override
  State<PickupOtpSheet> createState() => _PickupOtpSheetState();
}

class _PickupOtpSheetState extends State<PickupOtpSheet> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `ListenableBuilder` because the sheet holds the controller rather than
    // reading it from `context`, and a widget that reads a `ChangeNotifier` it
    // holds without listening to it is a widget that cannot change. The
    // controller sets `error` and notifies; without this the sheet redraws with
    // the same empty state, and the one thing the driver most needs to read --
    // "that code is not right" -- never appears.
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 32.h),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Confirm your rider',
              style: MngTheme.light.textTheme.titleLarge,
            ),
            SizedBox(height: 6.h),
            Text(
              'Ask your rider for the 4-digit pickup code before you start.',
              style: MngTheme.light.textTheme.bodySmall,
            ),
            SizedBox(height: 20.h),
            TextField(
              key: const Key('pickupOtpField'),
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 4,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                hintText: '0000',
                counterText: '',
              ),
            ),
            if (widget.controller.error != null) ...[
              SizedBox(height: 8.h),
              Text(
                widget.controller.error!,
                key: const Key('pickupOtpError'),
                style: const TextStyle(color: MngColors.error),
              ),
            ],
            SizedBox(height: 20.h),
            FilledButton(
              key: const Key('pickupOtpConfirmButton'),
              onPressed: widget.controller.busy
                  ? null
                  : () async {
                      final ok = await widget.controller.submitPickupOtp(
                        _code.text,
                      );
                      if (ok && context.mounted) Navigator.of(context).pop();
                    },
              child: const Text('Start trip'),
            ),
          ],
        ),
      ),
    );
  }
}
