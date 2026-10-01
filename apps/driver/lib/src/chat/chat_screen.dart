import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import 'chat_controller.dart';

/// The conversation with the rider on the active trip.
///
/// A driver's phone is in a mount and a rider's is in a hand, so the whole screen
/// is built around that: one row, everything reachable with a thumb, nothing that
/// needs a second hand.
///
/// Three decisions that are not obvious:
///
/// **The list does not auto-scroll on every message.** It scrolls to the bottom
/// when the driver opens the thread and when *they* send, and leaves the
/// position alone when the rider's message arrives and they have scrolled up.
/// Scrolling someone away from the history they are reading is the one thing a
/// chat screen must not do, and "scroll to the newest message" is the default in
/// every chat library.
///
/// **Sending is optimistic in the one direction that is safe.** The text leaves
/// the composer immediately and the bubble appears when the realtime stream
/// reports the row. A local bubble would be a second one with the same text for
/// as long as the round trip takes, which is exactly long enough for a driver on
/// a poor connection to see.
///
/// **Nothing is deleted and nothing is blocked.** There is no block button and no
/// "report" link here; a report is a deliberate act with a reason, and it belongs
/// on its own screen rather than three taps into a conversation.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.controller,
    this.riderName = 'Rider',
  });

  final ChatController controller;

  /// Shown in the app bar and as the attribution on an incoming message. The
  /// driver is not messaging a uuid, and an avatar-less thread labelled only by
  /// "Rider" is harder to follow than one with a name.
  final String riderName;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Started from the screen rather than the constructor, so a controller handed
    // in by a test is already listening and a second `load` does not double it.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.controller.load());
  }

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Scroll to the newest message, if the driver is already near the bottom.
  ///
  /// The "already near the bottom" test is what stops this yanking someone out of
  /// history. A driver reading back through a conversation to find an address has
  /// a scroll position that is not near the bottom, and that position is theirs.
  void _scrollToEnd({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (!force) {
        final position = _scroll.position;
        final distanceFromBottom = position.maxScrollExtent - position.pixels;
        if (distanceFromBottom > 160) return;
      }
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _composer.text;
    final ok = await widget.controller.send(text);
    if (!mounted) return;
    if (ok) {
      _composer.clear();
      _scrollToEnd(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.riderName),
        // The phone is in a mount; "back" is a gesture that a mounted phone may
        // not be in a position to receive.
        automaticallyImplyLeading: false,
        leading: IconButton(
          key: const Key('chatCloseButton'),
          icon: const Icon(Icons.close),
          tooltip: 'Close chat',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) {
                final c = widget.controller;
                if (c.loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (c.messages.isEmpty) {
                  return _Empty(
                    riderName: widget.riderName,
                    problem: c.problem,
                  );
                }
                return ListView.builder(
                  key: const Key('chatList'),
                  controller: _scroll,
                  // A little padding at the bottom so the last bubble is not
                  // flush against the composer, and so the keyboard opening does
                  // not sit on top of the message being read.
                  padding: EdgeInsets.fromLTRB(16.w, 16.h, 16.w, 24.h),
                  itemCount: c.messages.length,
                  itemBuilder: (context, index) {
                    final message = c.messages[index];
                    return _Bubble(
                      message: message,
                      mine: message.isMine(c.myId),
                      riderName: widget.riderName,
                    );
                  },
                );
              },
            ),
          ),
          _Composer(
            controller: _composer,
            onSend: _send,
          ),
        ],
      ),
      // Listens to the composer as well as the controller, and that is not
      // redundancy.
      //
      // The first version animated on the controller alone, so typing never
      // rebuilt the button: `TextEditingController` notifies its own listeners,
      // not the `ChatController`, and nothing else changes when a character is
      // typed. The send button therefore stayed disabled for the whole of a
      // message and the driver could not send anything at all -- a screen that
      // looks complete, has a working field, and has no working button.
      floatingActionButton: ListenableBuilder(
        listenable: Listenable.merge([widget.controller, _composer]),
        builder: (context, _) {
          final sendable = ChatController.isSendable(_composer.text) &&
              !widget.controller.sending;
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: FloatingActionButton.small(
              key: const Key('chatSendButton'),
              onPressed: sendable ? _send : null,
              tooltip: 'Send',
              child: const Icon(Icons.send),
            ),
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}

/// The thread when there is nothing in it.
///
/// The two states are separated because they mean opposite things and a driver
/// needs to know which one they are looking at: an empty thread is normal at the
/// start of a trip, and a broken one is a fault. Rendering both as an empty list
/// would make a real failure look like silence from the rider.
class _Empty extends StatelessWidget {
  const _Empty({required this.riderName, this.problem});

  final String riderName;
  final String? problem;

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    final broken = problem != null;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32.w),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              broken ? Icons.cloud_off : Icons.chat_bubble_outline,
              size: 48,
              color: MngColors.textSub,
            ),
            SizedBox(height: 16.h),
            Text(
              broken ? 'Messages are not available' : 'No messages yet',
              textAlign: TextAlign.center,
              style: theme.titleSmall,
            ),
            SizedBox(height: 6.h),
            Text(
              broken
                  // Not the raw problem, and not null: the driver is told the
                  // screen is broken and offered the one thing that helps.
                  ? '$problem You can still call them.'
                  : 'Say hello, or tell $riderName you are on the way.',
              key: Key(broken ? 'chatBrokenNote' : 'chatEmptyNote'),
              textAlign: TextAlign.center,
              style: theme.bodySmall?.copyWith(color: MngColors.textSub),
            ),
          ],
        ),
      ),
    );
  }
}

/// One message.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, required this.riderName});

  final ChatMessage message;
  final bool mine;
  final String riderName;

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    // The driver's own messages are the brand colour on the right; the rider's
    // are a neutral surface on the left. Alignment alone would do it, but the
    // colour is what makes a glance down the column readable at driving speed.
    final background = mine ? MngColors.primary : MngColors.muted;
    final foreground = mine ? MngColors.onPrimary : MngColors.textPrimary;

    return Padding(
      padding: EdgeInsets.only(bottom: 10.h),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!mine)
            Padding(
              padding: EdgeInsets.only(bottom: 2.h, left: 4.w),
              child: Text(riderName, style: theme.labelSmall),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12.w),
                  topRight: Radius.circular(12.w),
                  // A tail on the bubble's own side. Small, and it is what stops
                  // the column reading as a stack of rectangles.
                  bottomLeft: Radius.circular(mine ? 12.w : 3.w),
                  bottomRight: Radius.circular(mine ? 3.w : 12.w),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.body,
                    key: Key('chatBody_${message.id}'),
                    style: theme.bodyMedium?.copyWith(color: foreground),
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    message.clockLabel,
                    // Dimmed rather than omitted: when somebody said "wait 2
                    // minutes" is usually part of what they said.
                    style: theme.labelSmall?.copyWith(
                      color: foreground.withValues(alpha: 0.65),
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

/// The message field.
class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onSend});

  final TextEditingController controller;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    return AnimatedBuilder(
      // The composer is animated, not the screen, so typing rebuilds one field
      // rather than the whole thread. On a slow phone with twenty messages in it
      // that is the difference between typing and not typing.
      animation: controller,
      builder: (context, _) => SafeArea(
        top: false,
        child: Container(
          padding: EdgeInsets.fromLTRB(12.w, 8.h, 12.w, 8.h),
          decoration: const BoxDecoration(
            color: MngColors.surface,
            border: Border(top: BorderSide(color: MngColors.divider)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('chatComposer'),
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: ChatController.kMaxLength,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.newline,
                  // The return key inserts a newline on purpose: a driver holding
                  // a phone one-handed with a passenger cannot hit Send without
                  // letting go of the wheel to look for it, and the send button is
                  // right there for the messages that matter.
                  keyboardType: TextInputType.multiline,
                  inputFormatters: [LengthLimitingTextInputFormatter(ChatController.kMaxLength)],
                  decoration: InputDecoration(
                    hintText: 'Message',
                    counterText: '',
                    isDense: true,
                    errorText: ChatController.problemFor(controller.text) == null
                        ? null
                        : ChatController.problemFor(controller.text),
                    errorStyle: theme.labelSmall,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}