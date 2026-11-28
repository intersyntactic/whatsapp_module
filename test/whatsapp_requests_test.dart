import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_web_request_vocabulary/is_web_request_vocabulary.dart';
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart';
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart';
import 'package:is_whatsapp_module/is_whatsapp_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final phone = PhoneNumberId.parse(ourPhoneId)!;
  final signIn = SignIn.parse('claude-whatsapp')!;
  final theGroup = WhatsAppRecipient.group(GroupId.parse(groupId)!);

  ProposedRequest send(WhatsAppRecipient to, String text) =>
      whatsappTextRequest(
        from: phone,
        to: to,
        text: WhatsAppText.parse(text)!,
        signIn: signIn,
      );

  group('a text message', () {
    test('goes to the phone number\'s messages endpoint on Graph', () {
      final r = send(theGroup, 'hello');
      expect(r.origin, Origin.parse('https://graph.facebook.com'));
      expect(r.method, Method.post);
      expect(r.path.value, '/v27.0/$ourPhoneId/messages');
      expect(r.signIn, signIn);
    });

    test('to a group names it as a group', () {
      final body = JsonObject.decode(send(theGroup, 'hello').body!);
      expect(body.string('messaging_product'), 'whatsapp');
      expect(body.string('recipient_type'), 'group');
      expect(body.string('to'), groupId);
      expect(body.string('type'), 'text');
      expect(body.object('text').string('body'), 'hello');
    });

    test('to a person names them by phone number', () {
      final person = WhatsAppRecipient.person(
        WhatsAppPhoneNumber.parse('61400000000')!,
      );
      final body = JsonObject.decode(send(person, 'hi').body!);
      expect(body.string('recipient_type'), 'individual');
      expect(body.string('to'), '61400000000');
    });

    test('carries no credential: the sign-in adds the token', () {
      final r = send(theGroup, 'hello');
      expect(
        r.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
    });

    test('is covered by the prefix a rule grants for the number', () {
      final r = send(theGroup, 'hello');
      expect(whatsappSendPrefix(phone).covers(r.path), isTrue);
      // So the airlock can grant it under that prefix.
      expect(
        () => GrantedRequest.under(r, whatsappSendPrefix(phone)),
        returnsNormally,
      );
    });

    test('is not covered by another number\'s prefix', () {
      final other = PhoneNumberId.parse(otherPhoneId)!;
      expect(
        whatsappSendPrefix(other).covers(send(theGroup, 'x').path),
        isFalse,
      );
    });

    test(
      'the prefix does not cover the number itself, where its webhook is set',
      () {
        // POST /v27.0/<id> sets the number's override callback; a send grant
        // must never reach it.
        final bare = WebPath.parse('/v27.0/$ourPhoneId')!;
        expect(whatsappSendPrefix(phone).covers(bare), isFalse);
      },
    );
  });

  group('WhatsApp text', () {
    test('refuses empty and blank text', () {
      expect(WhatsAppText.parse(''), isNull);
      expect(WhatsAppText.parse('  \n '), isNull);
    });

    test('takes up to 4096 characters, and no more', () {
      expect(WhatsAppText.parse('a' * 4096), isNotNull);
      expect(WhatsAppText.parse('a' * 4097), isNull);
    });

    test('splits long text at whitespace into pieces that each fit', () {
      final words = List.filled(2000, 'word').join(' ');
      final pieces = WhatsAppText.split(words);
      expect(pieces.length, greaterThan(1));
      for (final p in pieces) {
        expect(p.value.length, lessThanOrEqualTo(4096));
        expect(p.value, isNot(startsWith(' ')));
      }
      expect(pieces.map((p) => p.value).join(' '), words);
    });

    test('splits text with no whitespace at the limit', () {
      final pieces = WhatsAppText.split('x' * 9000);
      expect(pieces.map((p) => p.value.length), [4096, 4096, 808]);
    });

    test('splits nothing out of blank text', () {
      expect(WhatsAppText.split('   '), isEmpty);
    });

    test('counts characters, not UTF-16 code units, so an emoji is one', () {
      expect(WhatsAppText.parse('🥦' * 4096), isNotNull);
      expect(WhatsAppText.parse('🥦' * 4097), isNull);
      for (final p in WhatsAppText.split('🥦' * 5000)) {
        // Never cut through the middle of a character.
        expect(utf8.decode(utf8.encode(p.value)), p.value);
      }
    });
  });

  test('a phone number is digits only, the way Meta writes wa_id', () {
    expect(WhatsAppPhoneNumber.parse('61400000000'), isNotNull);
    expect(WhatsAppPhoneNumber.parse('+61 400 000 000'), isNull);
    expect(WhatsAppPhoneNumber.parse('12'), isNull);
  });

  group('the reply endpoint', () {
    final person = WhatsAppRecipient.person(
      WhatsAppPhoneNumber.parse('61400000000')!,
    );
    final someoneElse = WhatsAppRecipient.person(
      WhatsAppPhoneNumber.parse('61400000001')!,
    );

    bool admits(WhatsAppRecipient chat, ProposedRequest r) {
      final endpoint = whatsappReplyEndpoint(from: phone, to: chat);
      return endpoint.admitsAddress(r.origin, r.path) &&
          endpoint.admitsBody(
            contentType: r.headers['content-type']!,
            body: r.body!,
          );
    }

    test('admits what the send builds for its own chat', () {
      expect(admits(theGroup, send(theGroup, 'hello')), isTrue);
      expect(admits(person, send(person, 'hello')), isTrue);
    });

    test('refuses a send to another chat', () {
      expect(admits(person, send(someoneElse, 'hello')), isFalse);
      expect(admits(person, send(theGroup, 'hello')), isFalse);
    });

    test('refuses a body that also names a recipient by user id', () {
      final endpoint = whatsappReplyEndpoint(from: phone, to: person);
      final sent = JsonObject.decode(send(person, 'hello').body!);
      expect(
        endpoint.admitsBody(
          contentType: 'application/json',
          body: jsonEncode(sent.withFields({'recipient': 'AU.someone-else'})),
        ),
        isFalse,
      );
    });
  });
}
