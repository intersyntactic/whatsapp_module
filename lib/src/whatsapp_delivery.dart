/// Meta's account of one webhook POST: the changes it carries, read from
/// the bytes the signature covered. The relay's gate reads it to decide,
/// and the module's reading reads the same bytes back from the logbook with
/// the same parser, so the two never disagree about a body.
///
/// One POST can carry several entries, each several changes, each several
/// messages or statuses. A part this can't read is left out and the rest
/// is kept, since every part is recorded either way, cut one item to an
/// entry by [WhatsAppDelivery.oneItemBodies].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';

import 'whatsapp_ids.dart';

final class WhatsAppDelivery {
  const WhatsAppDelivery._(this._root, this.changes);

  final JsonObject _root;

  final List<WhatsAppChange> changes;

  /// The body cut into bodies of one item each: one per message, one per
  /// status, and one per change of any other kind, each still a webhook
  /// body that [parse] reads. Each keeps its entry's fields and its change's
  /// `value` fields other than `messages` and `statuses`, such as
  /// `metadata` and `contacts`.
  ///
  /// The cut follows the body as sent, not what [parse] could read of it,
  /// so an item this module can't read is recorded all the same.
  List<Uint8List> get oneItemBodies {
    final bodies = <Uint8List>[];
    void add(JsonObject entry) => bodies.add(
      utf8.encode(
        jsonEncode(
          _root.withFields({
            'entry': [entry],
          }),
        ),
      ),
    );
    for (final entry in _root.objects('entry')) {
      // wire-ok: Meta's changes list, cut as sent.
      if (entry.raw('changes') case final List<Object?> changes) {
        for (final change in changes) {
          final items = _items(change);
          if (items.isEmpty) {
            add(
              entry.withFields({
                'changes': [change],
              }),
            );
          }
          for (final item in items) {
            add(
              entry.withFields({
                'changes': [item],
              }),
            );
          }
        }
      } else {
        add(entry);
      }
    }
    return bodies;
  }

  /// One copy of [change] per message and per status it carries, holding
  /// only that one; none for a change with neither.
  static List<JsonObject> _items(Object? change) {
    final c = JsonObject.parse(change);
    final value = JsonObject.parse(c?.raw('value'));
    if (c == null || value == null) return const [];
    final rest = value.without(_itemLists);
    return [
      for (final list in _itemLists)
        // wire-ok: Meta's item lists, cut as sent.
        if (value.raw(list) case final List<Object?> items)
          for (final item in items)
            c.withFields({
              'value': rest.withFields({
                list: [item],
              }),
            }),
    ];
  }

  static const _itemLists = ['messages', 'statuses'];

  /// Every message in every `messages` change, in the body's order.
  Iterable<InboundMessage> get messages => [
    for (final c in changes)
      if (c case MessagesChange(:final messages)) ...messages,
  ];

  /// Every status in every `messages` change, in the body's order.
  Iterable<DeliveryStatus> get statuses => [
    for (final c in changes)
      if (c case MessagesChange(:final statuses)) ...statuses,
  ];

  /// The business numbers the `messages` changes are for.
  Set<PhoneNumberId> get phoneNumberIds => {
    for (final c in changes)
      if (c case MessagesChange(:final phoneNumberId)) phoneNumberId,
  };

  /// [bytes] as a delivery; null unless they are a JSON object whose
  /// `object` is `whatsapp_business_account` and whose `entry` is a list.
  static WhatsAppDelivery? parse(List<int> bytes) {
    final JsonObject root;
    try {
      root = JsonObject.decode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    // wire-ok: Meta's object kind, checked once at the wire.
    if (root.raw('object') != 'whatsapp_business_account') return null;
    final List<JsonObject> entries;
    try {
      entries = root.objects('entry');
    } on FormatException {
      return null;
    }
    return WhatsAppDelivery._(
      root,
      List.unmodifiable([
        for (final entry in entries)
          for (final change in _orEmpty(() => entry.objects('changes')))
            ?WhatsAppChange._read(change),
      ]),
    );
  }
}

/// One `{"field", "value"}` change.
sealed class WhatsAppChange {
  const WhatsAppChange();

  static WhatsAppChange? _read(JsonObject change) {
    try {
      final field = WebhookField.parse(change.string('field'));
      final value = change.object('value');
      return switch (field) {
        WebhookField.messages => MessagesChange._read(value),
        null => null,
        (WebhookField.groupLifecycleUpdate ||
                WebhookField.groupParticipantsUpdate ||
                WebhookField.groupSettingsUpdate ||
                WebhookField.groupStatusUpdate) &&
            final WebhookField group =>
          GroupChange._(group, value),
      };
    } on FormatException {
      return null;
    }
  }
}

/// The webhook fields this module subscribes to. Groups' four have fields
/// of their own; a group's messages and statuses come in `messages`.
enum WebhookField {
  messages('messages'),
  groupLifecycleUpdate('group_lifecycle_update'),
  groupParticipantsUpdate('group_participants_update'),
  groupSettingsUpdate('group_settings_update'),
  groupStatusUpdate('group_status_update');

  const WebhookField(this.wire);

  final String wire;

  static WebhookField? parse(String s) {
    for (final f in values) {
      if (f.wire == s) return f;
    }
    return null;
  }
}

/// A `messages` change: what people sent the number, and what became of
/// what it sent.
final class MessagesChange extends WhatsAppChange {
  const MessagesChange._({
    required this.phoneNumberId,
    required this.messages,
    required this.statuses,
  });

  /// The business number it is for, from `metadata.phone_number_id`.
  final PhoneNumberId phoneNumberId;

  final List<InboundMessage> messages;
  final List<DeliveryStatus> statuses;

  /// Null without a phone number id: a change that can't say which number
  /// it is for is one the relay can't hold to its own.
  static MessagesChange? _read(JsonObject value) {
    final id = PhoneNumberId.parse(
      value.object('metadata').string('phone_number_id'),
    );
    if (id == null) return null;
    return MessagesChange._(
      phoneNumberId: id,
      messages: List.unmodifiable([
        for (final m in _orEmpty(() => value.objectsOrNull('messages') ?? []))
          ?InboundMessage._read(m),
      ]),
      statuses: List.unmodifiable([
        for (final s in _orEmpty(() => value.objectsOrNull('statuses') ?? []))
          ?DeliveryStatus._read(s),
      ]),
    );
  }
}

/// A change in one of the four group fields, kept as Meta sent it until a
/// reading needs more of it.
final class GroupChange extends WhatsAppChange {
  const GroupChange._(this.field, this.value);

  final WebhookField field;
  final JsonObject value;
}

/// A message someone sent: in a group when [group] is set.
final class InboundMessage {
  const InboundMessage._({
    required this.id,
    required this.from,
    required this.fromPhone,
    required this.group,
    required this.sentAt,
    required this.text,
    required this.replyTo,
  });

  final WhatsAppMessageId id;

  /// The sender's business-scoped user id, `from_user_id`. Meta sends it
  /// even when it withholds the phone number.
  final WhatsAppUserId? from;

  /// The sender's phone number, `from`, digits only; absent for someone
  /// who uses a username.
  final String? fromPhone;

  final GroupId? group;

  /// When they sent it, by Meta's `timestamp` in seconds.
  final DateTime? sentAt;

  /// What they wrote, when it is a text message.
  final String? text;

  /// The message it replies to, from `context.id`.
  final WhatsAppMessageId? replyTo;

  static InboundMessage? _read(JsonObject m) {
    try {
      final id = WhatsAppMessageId.parse(m.string('id'));
      if (id == null) return null;
      return InboundMessage._(
        id: id,
        from: switch (m.stringOrNull('from_user_id')) {
          final s? => WhatsAppUserId.parse(s),
          null => null,
        },
        fromPhone: m.stringOrNull('from'),
        group: switch (m.stringOrNull('group_id')) {
          final s? => GroupId.parse(s),
          null => null,
        },
        sentAt: _seconds(m.stringOrNull('timestamp')),
        // wire-ok: Meta's message type, checked once at the wire.
        text: m.raw('type') == 'text'
            ? m.objectOrNull('text')?.stringOrNull('body')
            : null,
        replyTo: switch (m.objectOrNull('context')?.stringOrNull('id')) {
          final s? => WhatsAppMessageId.parse(s),
          null => null,
        },
      );
    } on FormatException {
      return null;
    }
  }
}

/// Where a message the business sent has got to. Accepted is not
/// delivered: the send endpoint's 200 says only that Meta took it, and
/// these say what happened next.
enum DeliveryState {
  sent('sent'),
  delivered('delivered'),
  read('read'),
  failed('failed');

  const DeliveryState(this.wire);

  final String wire;

  static DeliveryState? parse(String s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// One status of [message]. In a group, `delivered` and `read` come once
/// per participant, named by [participant].
final class DeliveryStatus {
  const DeliveryStatus._({
    required this.message,
    required this.state,
    required this.participant,
    required this.group,
    required this.errorCodes,
    required this.stateAsSent,
  });

  final WhatsAppMessageId message;

  /// Null for a state this module doesn't know, which is kept all the same.
  final DeliveryState? state;

  final WhatsAppUserId? participant;

  /// The group it was sent to, when `recipient_type` is `group`.
  final GroupId? group;

  /// Meta's codes for why it failed, such as 131047 for a message outside
  /// the 24-hour window.
  final List<int> errorCodes;

  /// The state as Meta wrote it, so two states this module doesn't know
  /// are still told apart.
  final String stateAsSent;

  static DeliveryStatus? _read(JsonObject s) {
    try {
      final id = WhatsAppMessageId.parse(s.string('id'));
      if (id == null) return null;
      final stateWire = s.string('status');
      return DeliveryStatus._(
        stateAsSent: stateWire,
        message: id,
        state: DeliveryState.parse(stateWire),
        participant: switch (s.stringOrNull('recipient_participant_user_id')) {
          final p? => WhatsAppUserId.parse(p),
          null => null,
        },
        // wire-ok: Meta's recipient kind, checked once at the wire.
        group: s.raw('recipient_type') == 'group'
            ? GroupId.parse(s.string('recipient_id'))
            : null,
        errorCodes: List.unmodifiable([
          for (final e in _orEmpty(() => s.objectsOrNull('errors') ?? []))
            if (e.raw('code') case final int code) code,
        ]),
      );
    } on FormatException {
      return null;
    }
  }
}

DateTime? _seconds(String? s) => switch (int.tryParse(s ?? '')) {
  final n? => DateTime.fromMillisecondsSinceEpoch(n * 1000, isUtc: true),
  null => null,
};

List<JsonObject> _orEmpty(List<JsonObject> Function() read) {
  try {
    return read();
  } on FormatException {
    return const [];
  }
}
