import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../data/booked_trip.dart';
import '../data/chat_repository.dart';
import '../trip/trip_copy.dart';
import 'chat_controller.dart';

/// Per-trip messaging over `chat_messages`.
///
/// The trip list is the rider's own rides, because `trip chat read` and
/// `trip chat insert` both require the caller to be the rider or the driver on
/// that trip: a conversation about a trip the rider is not party to is refused
/// by the database, so the only trips worth offering here are their own.
///
/// The send button is live only for a body of 1..500 characters. 500 is
/// `chat_messages.body`'s own check constraint, not a number this screen
/// invented, and a body outside it is rejected by PostgREST rather than
/// trimmed.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.forOneTrip = false});

  /// Whether this screen was pushed for one specific ride rather than opened as
  /// the Chat tab.
  ///
  /// It changes the back button and nothing else, because it changes what "back"
  /// *means*: from a ride there is somewhere to go back to, and from the tab there
  /// is only the list of other rides. Without it a rider who pressed "Message
  /// driver" mid-ride and then pressed back landed in the trip picker instead of
  /// back on their ride.
  final bool forOneTrip;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _field = TextEditingController();
  final _fieldKey = const Key('messageField');

  @override
  void initState() {
    super.initState();
    _field.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ChatController>().loadRides();
    });
  }

  void _onChanged() {
    // The send button's enabled state is derived from the text, so the button
    // has to be repainted when the text changes and this controller is not a
    // ChangeNotifier the tree watches.
    setState(() {});
  }

  @override
  void dispose() {
    _field.removeListener(_onChanged);
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ChatController>();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        // Two different backs for two different ways in.
        //
        // Opened from the Chat tab, this screen is a list of rides and a thread,
        // and going back from a thread means choosing another ride -- which is
        // what `closeTrip` does.
        //
        // Opened by pressing "Message driver" on a live ride, there is no list:
        // the rider pushed one specific conversation from one specific screen,
        // and pressing back must return them to the ride they are on. It used to
        // put them in the trip picker instead, which is a screen belonging to a
        // part of the app they had left, and left them with no way back to the
        // driver they were trying to reach.
        leading: widget.forOneTrip
            ? IconButton(
                key: const Key('backOutOfChat'),
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back to your ride',
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : c.stage == ChatStage.thread
            ? IconButton(
                key: const Key('backToTrips'),
                icon: const Icon(Icons.arrow_back),
                onPressed: c.closeTrip,
              )
            : null,
        title: Text(
          widget.forOneTrip || c.stage == ChatStage.thread ? 'Messages' : 'Chat',
          style: MngTheme.light.textTheme.titleLarge,
        ),
      ),
      body: SafeArea(
        top: false,
        child: c.stage == ChatStage.picking
            ? _TripPicker(controller: c)
            : _Thread(controller: c, field: _field, fieldKey: _fieldKey),
      ),
    );
  }
}

class _TripPicker extends StatelessWidget {
  const _TripPicker({required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.loadingTrips && controller.rides.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.error != null && controller.rides.isEmpty) {
      return _Notice(
        icon: Icons.cloud_off_outlined,
        title: 'Your rides did not load',
        body: controller.error!,
        onRetry: controller.loadRides,
      );
    }
    if (controller.rides.isEmpty) {
      return const _Notice(
        icon: Icons.forum_outlined,
        title: 'No conversations yet',
        body: 'Chat with a driver once you have booked a ride.',
      );
    }
    return RefreshIndicator(
      onRefresh: controller.loadRides,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 24.h),
        itemCount: controller.rides.length,
        separatorBuilder: (_, _) => SizedBox(height: 10.h),
        itemBuilder: (context, i) => _TripTile(ride: controller.rides[i]),
      ),
    );
  }
}

class _TripTile extends StatelessWidget {
  const _TripTile({required this.ride});

  final BookedTrip ride;

  @override
  Widget build(BuildContext context) {
    final trip = ride.trip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.read<ChatController>().openTrip(ride),
      child: Container(
        key: Key('chatTrip-${ride.id}'),
        padding: EdgeInsets.all(16.w),
        decoration: BoxDecoration(
          color: MngColors.surface,
          borderRadius: BorderRadius.circular(MngRadius.large),
          border: Border.all(color: MngColors.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: MngColors.muted,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.chat_bubble_outline, size: 20),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stopLabel(trip.dropoff),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MngTheme.light.textTheme.titleMedium,
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    '${tripStateLabel(trip.state)} · ${formatTripMoment(ride.createdAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MngTheme.light.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _Thread extends StatelessWidget {
  const _Thread({
    required this.controller,
    required this.field,
    required this.fieldKey,
  });

  final ChatController controller;
  final TextEditingController field;
  final Key fieldKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (controller.error != null)
          Padding(
            padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 0),
            child: _ErrorLine(message: controller.error!),
          ),
        Expanded(
          child: controller.messages.isEmpty && !controller.loadingThread
              ? const _Notice(
                  icon: Icons.waving_hand_outlined,
                  title: 'No messages yet',
                  body: 'Say hello to your driver.',
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 12.h),
                  itemCount: controller.messages.length,
                  itemBuilder: (context, i) {
                    final m = controller.messages[i];
                    return _Bubble(
                      message: m,
                      mine:
                          controller.selfId != null &&
                          m.senderId == controller.selfId,
                    );
                  },
                ),
        ),
        _Composer(controller: controller, field: field, fieldKey: fieldKey),
      ],
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.field,
    required this.fieldKey,
  });

  final ChatController controller;
  final TextEditingController field;
  final Key fieldKey;

  @override
  Widget build(BuildContext context) {
    final canSend = controller.canSend(field.text);
    final overLimit = field.text.characters.length > ChatMessage.maxLength;
    return Container(
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 12.h),
      decoration: const BoxDecoration(
        color: MngColors.page,
        border: Border(top: BorderSide(color: MngColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (overLimit) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${field.text.characters.length} characters. Messages are '
                'limited to ${ChatMessage.maxLength}.',
                style: const TextStyle(color: MngColors.error),
              ),
            ),
            SizedBox(height: 4.h),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: fieldKey,
                  controller: field,
                  maxLines: 4,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: 'Message your driver',
                    isDense: true,
                    filled: true,
                    fillColor: MngColors.muted,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16.w,
                      vertical: 12.h,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(MngRadius.small),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              SizedBox(width: 10.w),
              SizedBox(
                height: 46,
                width: 46,
                child: FilledButton(
                  key: const Key('sendButton'),
                  onPressed: canSend ? () => _send() : null,
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: const CircleBorder(),
                  ),
                  child: controller.sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: MngColors.onPrimary,
                          ),
                        )
                      : const Icon(Icons.send, size: 20),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final sent = await controller.send(field.text);
    // Cleared only on success. A failed send leaves the rider's words in the
    // field, because a message they just typed is theirs and the network
    // taking it away is the opposite of helpful.
    if (sent) field.clear();
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});

  final ChatMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8.h),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
              decoration: BoxDecoration(
                color: mine ? MngColors.primary : MngColors.muted,
                borderRadius: BorderRadius.circular(MngRadius.small),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.body,
                    style: MngTheme.light.textTheme.bodyMedium?.copyWith(
                      color: mine ? MngColors.onPrimary : MngColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    formatTripMoment(message.createdAt),
                    style: MngTheme.light.textTheme.bodySmall?.copyWith(
                      fontSize: 10.sp,
                      color: mine
                          ? MngColors.onPrimary.withValues(alpha: 0.7)
                          : MngColors.textSub,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('chatError'),
      width: double.infinity,
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: MngColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(MngRadius.small),
      ),
      child: Text(message, style: const TextStyle(color: MngColors.error)),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.body,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String body;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: 32.w, vertical: 80.h),
      children: [
        Icon(icon, size: 40, color: MngColors.divider),
        SizedBox(height: 12.h),
        Text(
          title,
          textAlign: TextAlign.center,
          style: MngTheme.light.textTheme.titleMedium,
        ),
        SizedBox(height: 4.h),
        Text(
          body,
          textAlign: TextAlign.center,
          style: MngTheme.light.textTheme.bodySmall,
        ),
        if (onRetry != null) ...[
          SizedBox(height: 20.h),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Try again'),
          ),
        ],
      ],
    );
  }
}
