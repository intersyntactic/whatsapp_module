import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_whatsapp_module/is_whatsapp_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

const _first = 'wamid.FIRST';
const _second = 'wamid.SECOND';
const _sent = 'wamid.SENT';

/// One `messages` change holding [messages] and [statuses] together, as
/// Meta batches them.
Map<String, Object?> _batch(
  List<Map<String, Object?>> messages,
  List<Map<String, Object?>> statuses,
) => {
  'field': 'messages',
  'value': {
    'messaging_product': 'whatsapp',
    'metadata': metadata(ourPhoneId),
    'contacts': [
      {
        'profile': {'name': 'Sonia'},
        'wa_id': '61400000000',
      },
    ],
    'messages': messages,
    'statuses': statuses,
  },
};

Map<String, Object?> _text(String id) => {
  'from': '61400000000',
  'id': id,
  'timestamp': '1795000000',
  'group_id': groupId,
  'type': 'text',
  'text': {'body': 'hi'},
};

Map<String, Object?> _status(String state, String participant) => {
  'id': _sent,
  'status': state,
  'timestamp': '1795000001',
  'recipient_id': groupId,
  'recipient_type': 'group',
  'recipient_participant_user_id': participant,
};

List<WhatsAppDelivery> _cut(List<int> body) => [
  for (final item in WhatsAppDelivery.parse(body)!.oneItemBodies)
    WhatsAppDelivery.parse(item)!,
];

void main() {
  test('cuts a batch into one body per message and per status', () {
    final cut = _cut(
      webhookBody([
        _batch(
          [_text(_first), _text(_second)],
          [_status('delivered', 'AU.1'), _status('read', 'AU.2')],
        ),
      ]),
    );
    expect(cut, hasLength(4));
    expect(
      [for (final d in cut) d.messages.length + d.statuses.length],
      [1, 1, 1, 1],
    );
    expect(
      [for (final d in cut) ...d.messages.map((m) => m.id.value)],
      [_first, _second],
    );
    expect(
      [for (final d in cut) ...d.statuses.map((s) => s.stateAsSent)],
      ['delivered', 'read'],
    );
  });

  test('each piece keeps its number, its contacts and its group', () {
    final body = webhookBody([
      _batch([_text(_first), _text(_second)], []),
    ]);
    final message = _cut(body).first;
    expect(message.phoneNumberIds.map((p) => p.value), [ourPhoneId]);
    expect(message.messages.single.group?.value, groupId);
    final value = JsonObject.decode(
      utf8.decode(WhatsAppDelivery.parse(body)!.oneItemBodies.first),
    ).objects('entry').single.objects('changes').single.object('value');
    expect(value.objects('contacts'), hasLength(1));
    expect(value.has('statuses'), isFalse);
  });

  test('keeps a message it cannot read as a piece of its own', () {
    final unreadable = {'type': 'text'};
    final body = webhookBody([
      _batch([_text(_first), unreadable], []),
    ]);
    final items = WhatsAppDelivery.parse(body)!.oneItemBodies;
    expect(items, hasLength(2));
    final kept = JsonObject.decode(utf8.decode(items[1]))
        .objects('entry')
        .single
        .objects('changes')
        .single
        .object('value')
        .objects('messages')
        .single;
    expect(kept.string('type'), 'text');
    expect(kept.has('id'), isFalse);
  });

  test('keeps a group change whole, as one piece', () {
    final change = {
      'field': 'group_lifecycle_update',
      'value': {
        'metadata': metadata(ourPhoneId),
        'groups': [
          {'group_id': groupId, 'type': 'group_create'},
        ],
      },
    };
    final items = WhatsAppDelivery.parse(webhookBody([change]))!.oneItemBodies;
    expect(items, hasLength(1));
    expect(
      JsonObject.decode(utf8.decode(items.single))
          .objects('entry')
          .single
          .objects('changes')
          .single
          .string('field'),
      'group_lifecycle_update',
    );
  });

  test('cuts each of several changes', () {
    final cut = _cut(webhookBody([textMessageChange(), statusChange()]));
    expect(cut, hasLength(2));
  });
}
