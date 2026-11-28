import 'dart:convert';

import 'package:is_whatsapp_module/is_whatsapp_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final secret = MetaAppSecret.parse(testSecret)!;
  final ours = PhoneNumberId.parse(ourPhoneId)!;
  final token = WebhookVerifyToken.parse('the-verify-token')!;

  group('the sign-up handshake', () {
    HandshakeAnswer answer(Map<String, String> query) =>
        answerHandshake(query: query, token: token);

    test('answers the challenge when the token matches', () {
      expect(
        answer({
          'hub.mode': 'subscribe',
          'hub.verify_token': 'the-verify-token',
          'hub.challenge': '1158201444',
        }),
        isA<HandshakeAccepted>().having(
          (a) => a.challenge,
          'challenge',
          '1158201444',
        ),
      );
    });

    test('refuses a wrong token', () {
      expect(
        answer({
          'hub.mode': 'subscribe',
          'hub.verify_token': 'the-verify-tokeN',
          'hub.challenge': '1158201444',
        }),
        isA<HandshakeRefused>(),
      );
    });

    test('refuses a token that is a prefix of the right one', () {
      expect(
        answer({
          'hub.mode': 'subscribe',
          'hub.verify_token': 'the-verify',
          'hub.challenge': '1',
        }),
        isA<HandshakeRefused>(),
      );
    });

    test('refuses a token that starts with the right one', () {
      expect(
        answer({
          'hub.mode': 'subscribe',
          'hub.verify_token': 'the-verify-tokenXYZ',
          'hub.challenge': '1',
        }),
        isA<HandshakeRefused>(),
      );
    });

    test('refuses no token', () {
      expect(
        answer({'hub.mode': 'subscribe', 'hub.challenge': '1'}),
        isA<HandshakeRefused>(),
      );
    });

    test('refuses a mode other than subscribe', () {
      expect(
        answer({
          'hub.mode': 'unsubscribe',
          'hub.verify_token': 'the-verify-token',
          'hub.challenge': '1',
        }),
        isA<HandshakeRefused>(),
      );
    });

    test('refuses a challenge that is not a short plain word', () {
      for (final challenge in ['', '<script>', 'a b', 'x' * 300]) {
        expect(
          answer({
            'hub.mode': 'subscribe',
            'hub.verify_token': 'the-verify-token',
            'hub.challenge': challenge,
          }),
          isA<HandshakeRefused>(),
          reason: challenge,
        );
      }
    });
  });

  group('a delivery', () {
    final seen = <RepeatKey>{};
    setUp(seen.clear);

    DeliveryDecision decide(List<int> body, {String? signature}) =>
        decideDelivery(
          secret: secret,
          phoneNumberId: ours,
          body: body,
          signatureHeader: signature ?? metaSignature(body),
          hasSeen: seen.contains,
        );

    test('signed by Meta, for our number, is taken with its keys', () {
      final body = webhookBody([textMessageChange()]);
      final d = decide(body);
      expect(d, isA<DeliveryTaken>());
      expect((d as DeliveryTaken).keys, hasLength(1));
    });

    group('the signature', () {
      test('refuses a body changed after signing', () {
        final body = webhookBody([textMessageChange(text: 'hello')]);
        final tampered = webhookBody([textMessageChange(text: 'hellO')]);
        expect(
          decide(tampered, signature: metaSignature(body)),
          isA<DeliveryRefused>().having((r) => r.status, 'status', 403),
        );
      });

      test('refuses a signature made with another secret', () {
        final body = webhookBody([textMessageChange()]);
        expect(
          decide(body, signature: metaSignature(body, secret: 'not ours')),
          isA<DeliveryRefused>().having((r) => r.status, 'status', 403),
        );
      });

      test('refuses no signature, or one not in sha256=<hex> form', () {
        final body = webhookBody([textMessageChange()]);
        final good = metaSignature(body);
        for (final header in [
          '',
          good.substring('sha256='.length),
          'sha1=${good.substring('sha256='.length)}',
          '${good}00',
          good.substring(0, good.length - 2),
          'sha256=${'z' * 64}',
        ]) {
          expect(
            decide(body, signature: header),
            isA<DeliveryRefused>().having((r) => r.status, 'status', 403),
            reason: header,
          );
        }
      });

      test('is checked before the body is read as JSON', () {
        // Not JSON at all, and unsigned: refused as unsigned (403), not as
        // unreadable (400), so nothing of a stranger's bytes is parsed.
        final body = utf8.encode('{not json');
        expect(
          decide(body, signature: 'sha256=${'0' * 64}'),
          isA<DeliveryRefused>().having((r) => r.status, 'status', 403),
        );
      });
    });

    test('refuses a signed body that is not a webhook', () {
      final body = utf8.encode('{"object": "page", "entry": []}');
      expect(
        decide(body),
        isA<DeliveryRefused>().having((r) => r.status, 'status', 400),
      );
    });

    test('refuses a signed body that names a key twice', () {
      // Read last-wins, the second `object` would make this a webhook.
      final body = utf8.encode(
        '{"object": "page", '
        '"object": "whatsapp_business_account", "entry": []}',
      );
      expect(
        decide(body),
        isA<DeliveryRefused>().having((r) => r.status, 'status', 400),
      );
    });

    group('repeats', () {
      test('drops a delivery whose every key was seen', () {
        final body = webhookBody([textMessageChange()]);
        seen.addAll((decide(body) as DeliveryTaken).keys);
        expect(decide(body), isA<DeliveryRepeated>());
      });

      test('takes a delivery with one new key beside seen ones', () {
        final first = webhookBody([textMessageChange(id: 'wamid.AAAA')]);
        seen.addAll((decide(first) as DeliveryTaken).keys);
        final both = webhookBody([
          textMessageChange(id: 'wamid.AAAA'),
          textMessageChange(id: 'wamid.BBBB'),
        ]);
        expect(decide(both), isA<DeliveryTaken>());
      });

      test('keys a message by its id alone, not its body', () {
        final first = webhookBody([textMessageChange(text: 'one')]);
        seen.addAll((decide(first) as DeliveryTaken).keys);
        final again = webhookBody([textMessageChange(text: 'two')]);
        expect(decide(again), isA<DeliveryRepeated>());
      });

      test('keys a status by message, state and participant', () {
        final delivered = webhookBody([statusChange(status: 'delivered')]);
        seen.addAll((decide(delivered) as DeliveryTaken).keys);
        expect(decide(delivered), isA<DeliveryRepeated>());
        for (final next in [
          statusChange(status: 'read'),
          statusChange(participant: 'AU.9999999999999999999'),
          statusChange(id: 'wamid.OTHER'),
        ]) {
          expect(decide(webhookBody([next])), isA<DeliveryTaken>());
        }
      });

      test('a message and a status of the same id are two keys', () {
        final message = webhookBody([textMessageChange(id: 'wamid.SAME')]);
        seen.addAll((decide(message) as DeliveryTaken).keys);
        expect(
          decide(webhookBody([statusChange(id: 'wamid.SAME')])),
          isA<DeliveryTaken>(),
        );
      });
    });

    test('leaves out a delivery for another of the account\'s numbers', () {
      final body = webhookBody([textMessageChange(phoneId: otherPhoneId)]);
      expect(decide(body), isA<DeliveryNotForThisNumber>());
    });

    test('leaves out a delivery that mixes our number with another', () {
      final body = webhookBody([
        textMessageChange(),
        statusChange(phoneId: otherPhoneId),
      ]);
      expect(decide(body), isA<DeliveryNotForThisNumber>());
    });

    test('reads a failed status as failed, with Meta\'s code', () {
      final body = webhookBody([
        statusChange(
          status: 'failed',
          errors: [
            {'code': 131047, 'title': 'Re-engagement message'},
          ],
        ),
      ]);
      final taken = decide(body) as DeliveryTaken;
      final status = taken.delivery.statuses.single;
      expect(status.state, DeliveryState.failed);
      expect(status.errorCodes, [131047]);
    });

    test('reads a group message\'s group, sender and text', () {
      final taken = decide(webhookBody([textMessageChange()])) as DeliveryTaken;
      final m = taken.delivery.messages.single;
      expect(m.group?.value, groupId);
      expect(m.from?.value, 'AU.1234567890123456789');
      expect(m.text, 'hello');
    });
  });
}
