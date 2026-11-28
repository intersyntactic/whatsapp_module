import 'dart:convert';
import 'dart:typed_data';

import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart';
import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_logbook_format/is_logbook_format.dart';
import 'package:is_whatsapp_module/is_whatsapp_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

const translator = WhatsAppEventTranslator();

/// [body] as the docking station hands it over: recorded by the relay's
/// encoder, read back by its reader.
RelayedEvent relayed(List<int> body) {
  final (kind, entry) = encodeRelayedEvent(
    WhatsAppEventTranslator.whatsapp,
    at: DateTime.utc(2026, 11, 28),
    bytes: Uint8List.fromList(body),
  );
  return RelayedEvent.read(ObjectId.parse('0' * 64)!, kind, entry)!;
}

/// Steps through [bodies] from the start, as the docking station does.
List<TranslatedEvent> run(List<List<int>> bodies) {
  var state = translator.start;
  return [
    for (final body in bodies)
      () {
        final (next, event) = translator.step(state, relayed(body));
        state = next;
        return event;
      }(),
  ];
}

MessageSaid saidOf(TranslatedEvent event) =>
    event is MessageSaid ? event : fail('not something said: $event');

void main() {
  test('a text in a group is something said there', () {
    final said = saidOf(
      run([
        webhookBody([textMessageChange(id: 'wamid.A', text: 'hello')]),
      ]).single,
    );
    expect(said.addressInExternalSystem.value, 'whatsapp:group:$groupId');
    expect(said.containingAddress, isNull);
    expect(said.addressedTo?.value, 'whatsapp:number:$ourPhoneId');
    expect(said.replyEndpoint, isNull);
    expect(said.key.value, 'wamid.A');
    expect(said.node.author.value, 'whatsapp:user:AU.1234567890123456789');
    expect(said.node.source.value, 'wamid.A');
    expect(said.node.text, 'hello');
    expect(said.node.quotes, isNull);
  });

  test('a text outside a group is said in the chat with the number', () {
    final said = saidOf(
      run([
        webhookBody([textMessageChange(id: 'wamid.A', inGroup: false)]),
      ]).single,
    );
    expect(
      said.addressInExternalSystem.value,
      'whatsapp:chat:$ourPhoneId:AU.1234567890123456789',
    );
  });

  test('a reply names who wrote what it quotes, once that was seen', () {
    final [_, reply] = run([
      webhookBody([textMessageChange(id: 'wamid.A', userId: 'AU.first')]),
      webhookBody([
        textMessageChange(
          id: 'wamid.B',
          userId: 'AU.second',
          replyTo: 'wamid.A',
        ),
      ]),
    ]);
    final quote = saidOf(reply).node.quotes;
    expect(quote?.source.value, 'wamid.A');
    expect(
      quote?.author,
      isA<KnownAuthor>().having(
        (a) => a.actor.value,
        'actor',
        'whatsapp:user:AU.first',
      ),
    );
  });

  test('a reply to a message never seen quotes an unknown author', () {
    final reply = run([
      webhookBody([
        textMessageChange(id: 'wamid.B', replyTo: 'wamid.NEVERSEEN'),
      ]),
    ]).single;
    expect(saidOf(reply).node.quotes?.author, isA<UnknownAuthor>());
  });

  test('a status is nothing to admit', () {
    expect(
      run([
        webhookBody([statusChange()]),
      ]).single,
      isA<NothingToAdmit>(),
    );
  });

  test('bytes that are no webhook body are nothing to admit', () {
    expect(run([utf8.encode('not json')]).single, isA<NothingToAdmit>());
  });

  test('steps the same way twice from the start', () {
    final bodies = [
      webhookBody([textMessageChange(id: 'wamid.A', userId: 'AU.first')]),
      webhookBody([textMessageChange(id: 'wamid.B', replyTo: 'wamid.A')]),
    ];
    String said(List<TranslatedEvent> events) => jsonEncode([
      for (final e in events)
        if (e case MessageSaid(:final node)) node.toJson(),
    ]);
    expect(said(run(bodies)), said(run(bodies)));
  });

  test('leaves the state it was given as it was', () {
    final before = translator.start;
    translator.step(
      before,
      relayed(webhookBody([textMessageChange(id: 'wamid.A')])),
    );
    expect(before.of(SourceMessageId.parse('wamid.A')!), isNull);
  });
}
