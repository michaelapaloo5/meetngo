import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import 'earnings_controller.dart';
import 'payout_sheet.dart';

const _kindLabels = {
  'fare': 'Trip fare',
  'commission': 'Platform commission',
  'compensation': 'Cancellation compensation',
  'void': 'Voided charge',
  'bonus': 'Bonus',
};

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EarningsController>();
    final snapshot = controller.snapshot;
    final available = snapshot?.availableGhs ?? 0.0;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Earnings', style: MngTheme.light.textTheme.titleLarge),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
              child: Column(
                children: [
                  _BalanceTile(
                    tileKey: 'availableBalance',
                    label: 'Available',
                    amountGhs: available,
                    highlight: true,
                  ),
                  SizedBox(height: 12.h),
                  Row(
                    children: [
                      Expanded(
                        child: _BalanceTile(
                          tileKey: 'pendingBalance',
                          label: 'Pending',
                          amountGhs: snapshot?.pendingGhs ?? 0.0,
                        ),
                      ),
                      SizedBox(width: 12.w),
                      Expanded(
                        child: _BalanceTile(
                          tileKey: 'lifetimeEarnings',
                          label: 'Lifetime',
                          amountGhs: snapshot?.lifetimeGhs ?? 0.0,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (controller.error != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.w),
                child: Text(
                  controller.error!,
                  key: const Key('walletError'),
                  style: const TextStyle(color: MngColors.error),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 0),
              child: FilledButton(
                key: const Key('payoutButton'),
                onPressed: available <= 0
                    ? null
                    : () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => PayoutSheet(controller: controller),
                        ),
                child: const Text('Withdraw'),
              ),
            ),
            SizedBox(height: 16.h),
            Expanded(
              child: (snapshot?.entries.isEmpty ?? true)
                  ? Center(
                      child: Text(
                        'No earnings yet',
                        style: MngTheme.light.textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.symmetric(horizontal: 20.w),
                      itemCount: snapshot!.entries.length,
                      itemBuilder: (context, index) {
                        final entry = snapshot.entries[index];
                        return ListTile(
                          key: Key('ledgerRow-${entry.id}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(_kindLabels[entry.kind] ?? entry.kind),
                          subtitle: Text(
                            entry.createdAt.toIso8601String().substring(0, 10),
                            style: MngTheme.light.textTheme.bodySmall,
                          ),
                          trailing: Text(
                            '${entry.amountGhs >= 0 ? '+' : '-'}'
                            'GHS ${entry.amountGhs.abs().toStringAsFixed(2)}',
                            style: TextStyle(
                              color: entry.amountGhs >= 0
                                  ? MngColors.success
                                  : MngColors.error,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BalanceTile extends StatelessWidget {
  const _BalanceTile({
    required this.tileKey,
    required this.label,
    required this.amountGhs,
    this.highlight = false,
  });

  final String tileKey;
  final String label;
  final double amountGhs;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(tileKey),
      width: double.infinity,
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: highlight ? MngColors.textPrimary : MngColors.muted,
        borderRadius: BorderRadius.circular(MngRadius.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: MngTheme.light.textTheme.bodySmall?.copyWith(
              color: highlight ? MngColors.primary : MngColors.textSub,
            ),
          ),
          SizedBox(height: 4.h),
          Text(
            'GHS ${amountGhs.toStringAsFixed(2)}',
            style: MngTheme.light.textTheme.titleLarge?.copyWith(
              color: highlight ? Colors.white : MngColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
