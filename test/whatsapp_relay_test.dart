import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_whatsapp_module/is_whatsapp_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late HttpServer server;
  late HttpClient client;
  late List<String> logged;
  late List<Uint8List> recorded;
  late RecordAnswer Function() nextAnswer;

  setUp(() async {
    logged = [];
    recorded = [];
    nextAnswer = () => const Recorded('abc123');
    final relay = WhatsAppRelay(
      secret: MetaAppSecret.parse(testSecret)!,
      verifyToken: WebhookVerifyToken.parse('the-verify-token')!,
      phoneNumberId: PhoneNumberId.parse(ourPhoneId)!,
      record: (body) async {
        final answer = nextAnswer();
        if (answer is Recorded) recorded.add(body);
        return answer;
      },
      log: logged.add,
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) => unawaited(relay.handle(req)));
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  Uri at(String path, [Map<String, String>? query]) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: server.port,
    path: path,
    queryParameters: query,
  );

  Future<(int, String)> get(Uri uri) async {
    final res = await (await client.getUrl(uri)).close();
    return (res.statusCode, await utf8.decodeStream(res));
  }

  Future<int> post(List<int> body, {String? signature}) async {
    final req = await client.postUrl(at(WhatsAppRelay.path));
    req.headers.contentType = ContentType.json;
    if (signature != null) req.headers.set('x-hub-signature-256', signature);
    req.add(body);
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  }

  group('the handshake', () {
    test('answers the challenge as plain text', () async {
      final (status, body) = await get(
        at(WhatsAppRelay.path, {
          'hub.mode': 'subscribe',
          'hub.verify_token': 'the-verify-token',
          'hub.challenge': '424242',
        }),
      );
      expect(status, 200);
      expect(body, '424242');
    });

    test('refuses a wrong token with 403', () async {
      final (status, _) = await get(
        at(WhatsAppRelay.path, {
          'hub.mode': 'subscribe',
          'hub.verify_token': 'guess',
          'hub.challenge': '424242',
        }),
      );
      expect(status, 403);
    });

    test('logs neither spelling of the token', () async {
      // Meta sends the token as hub.verify_token; a proxy or framework may
      // also show it as hub_verify_token. The log is no place for either.
      for (final name in ['hub.verify_token', 'hub_verify_token']) {
        await get(
          at(WhatsAppRelay.path, {
            'hub.mode': 'subscribe',
            name: 'the-verify-token',
            'hub.challenge': '424242',
          }),
        );
      }
      expect(logged, isNotEmpty);
      for (final line in logged) {
        expect(line, isNot(contains('the-verify-token')));
        expect(line, isNot(contains('424242')));
        expect(line, isNot(contains('hub')));
      }
    });
  });

  group('a delivery', () {
    test('of one item is recorded as it came, then answered 200', () async {
      final body = webhookBody([textMessageChange()]);
      expect(await post(body, signature: metaSignature(body)), 200);
      expect(recorded.single, body);
    });

    test('of several items is recorded one entry each', () async {
      final body = webhookBody([
        textMessageChange(id: 'wamid.A'),
        textMessageChange(id: 'wamid.B'),
        statusChange(),
      ]);
      expect(await post(body, signature: metaSignature(body)), 200);
      expect(recorded, hasLength(3));
      expect(
        [for (final r in recorded) WhatsAppDelivery.parse(r)!.messages.length],
        [1, 1, 0],
      );
    });

    test('recorded partway gets a 500, and its retry is taken whole', () {
      final body = webhookBody([
        textMessageChange(id: 'wamid.A'),
        textMessageChange(id: 'wamid.B'),
      ]);
      var calls = 0;
      nextAnswer = () => ++calls == 2
          ? const RecordFailed('disk full')
          : const Recorded('abc123');
      return () async {
        expect(await post(body, signature: metaSignature(body)), 500);
        expect(recorded, hasLength(1));
        expect(await post(body, signature: metaSignature(body)), 200);
        expect(recorded, hasLength(3));
      }();
    });

    test('with no signature is refused 403 and not recorded', () async {
      final body = webhookBody([textMessageChange()]);
      expect(await post(body), 403);
      expect(recorded, isEmpty);
    });

    test('with a wrong signature is refused 403 and not recorded', () async {
      final body = webhookBody([textMessageChange()]);
      expect(
        await post(body, signature: metaSignature(body, secret: 'x')),
        403,
      );
      expect(recorded, isEmpty);
    });

    test('sent again is answered 200 and recorded once', () async {
      final body = webhookBody([textMessageChange()]);
      expect(await post(body, signature: metaSignature(body)), 200);
      expect(await post(body, signature: metaSignature(body)), 200);
      expect(recorded, hasLength(1));
    });

    test('not recorded gets a 500, and its retry is taken', () async {
      final body = webhookBody([textMessageChange()]);
      nextAnswer = () => const RecordUnanswered('socket: gone');
      expect(await post(body, signature: metaSignature(body)), 500);
      expect(recorded, isEmpty);
      nextAnswer = () => const Recorded('abc123');
      expect(await post(body, signature: metaSignature(body)), 200);
      expect(recorded, hasLength(1));
    });

    test('for another number is answered 200 and not recorded', () async {
      final body = webhookBody([textMessageChange(phoneId: otherPhoneId)]);
      expect(await post(body, signature: metaSignature(body)), 200);
      expect(recorded, isEmpty);
    });

    test('logs no one\'s words', () async {
      final body = webhookBody([
        textMessageChange(text: 'gluten-free for Sam'),
      ]);
      await post(body, signature: metaSignature(body));
      expect(logged.join('\n'), isNot(contains('gluten')));
    });
  });

  test('answers 404 off the callback path', () async {
    final (status, _) = await get(at('/elsewhere'));
    expect(status, 404);
  });
}
