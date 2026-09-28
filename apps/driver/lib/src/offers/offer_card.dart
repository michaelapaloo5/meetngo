import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class OfferCard extends StatelessWidget {
  const OfferCard({
    super.key,
    required this.offer,
    required this.onAccept,
    required this.onDecline,
  });

  final Offer offer;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final expired = offer.isExpired;
    return Container(
      key: Key('offer-${offer.id}'),
      margin: EdgeInsets.symmetric(horizontal: 20.w, vertical: 8.h),
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: MngColors.surface,
        borderRadius: BorderRadius.circular(MngRadius.large),
        border: Border.all(color: MngColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // `Flexible` on the fare, not on the countdown. The test font sets
              // every glyph to a full em box, so 'GHS 12.50' at titleLarge is
              // 162 logical pixels and the countdown pill is 74, against a
              // 316-pixel row -- and a phone at a large text scale overflows the
              // same way, because the fare grows and the pill does not shrink.
              Flexible(
                child: Text(
                  'GHS ${offer.fareGhs.toStringAsFixed(2)}',
                  overflow: TextOverflow.ellipsis,
                  style: MngTheme.light.textTheme.titleLarge,
                ),
              ),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: expired ? MngColors.muted : MngColors.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  expired ? 'Offer expired' : '${offer.secondsRemaining}s',
                  style: MngTheme.light.textTheme.bodySmall?.copyWith(
                    color: expired ? MngColors.textSub : MngColors.onPrimary,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8.h),
          Text(
            '${(offer.pickupDistanceKm * 1000).round()} m from the pickup point',
            style: MngTheme.light.textTheme.bodySmall,
          ),
          SizedBox(height: 16.h),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('declineOfferButton'),
                  onPressed: onDecline,
                  child: const Text('Decline'),
                ),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: FilledButton(
                  key: const Key('acceptOfferButton'),
                  onPressed: expired ? null : onAccept,
                  child: const Text('Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
