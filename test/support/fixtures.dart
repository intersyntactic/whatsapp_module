import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The app secret the tests sign with, and the one number the relay serves.
const testSecret = 'test-app-secret';
const ourPhoneId = '111222333444555';
const otherPhoneId = '1279664105233186';
const groupId = 'HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRBNjU5OUFFRTAzODEwMTQ0RgA';

/// `sha256=<hex>` over [body] under [secret], as Meta signs a webhook.
String metaSignature(List<int> body, {String secret = testSecret}) =>
    'sha256=${Hmac(sha256, utf8.encode(secret)).convert(body)}';

/// One webhook body holding [changes], each `{"field", "value"}`.
List<int> webhookBody(List<Map<String, Object?>> changes) => utf8.encode(
  jsonEncode({
    'object': 'whatsapp_business_account',
    'entry': [
      {'id': '900000000000001', 'changes': changes},
    ],
  }),
);

Map<String, Object?> metadata(String phoneId) => {
  'display_phone_number': '61390000000',
  'phone_number_id': phoneId,
};

/// A `messages` change carrying one text message, in a group when
/// [inGroup], the shape of Meta's groups webhook reference.
Map<String, Object?> textMessageChange({
  String phoneId = ourPhoneId,
  String id = 'wamid.HBgLNjE0MDAwMDAwMDAVAgASGBQzQUFBQUFBQUFBQUFBQUFBQUFBQQA=',
  String text = 'hello',
  String from = '61400000000',
  String userId = 'AU.1234567890123456789',
  bool inGroup = true,
  String? replyTo,
}) => {
  'field': 'messages',
  'value': {
    'messaging_product': 'whatsapp',
    'metadata': metadata(phoneId),
    'contacts': [
      {
        'profile': {'name': 'Sonia'},
        'wa_id': from,
        'user_id': userId,
      },
    ],
    'messages': [
      {
        'from': from,
        'from_user_id': userId,
        'id': id,
        'timestamp': '1795000000',
        'group_id': ?(inGroup ? groupId : null),
        'type': 'text',
        'text': {'body': text},
        if (replyTo != null) 'context': {'id': replyTo},
      },
    ],
  },
};

/// A `messages` change carrying one status of a message the business sent.
Map<String, Object?> statusChange({
  String phoneId = ourPhoneId,
  String id = 'wamid.HBgLOUTGOING0000000000000000000000000000000000AA=',
  String status = 'delivered',
  String? participant = 'AU.1234567890123456789',
  List<Map<String, Object?>>? errors,
}) => {
  'field': 'messages',
  'value': {
    'messaging_product': 'whatsapp',
    'metadata': metadata(phoneId),
    'statuses': [
      {
        'id': id,
        'status': status,
        'timestamp': '1795000001',
        'recipient_id': groupId,
        'recipient_type': 'group',
        'recipient_participant_user_id': ?participant,
        'errors': ?errors,
      },
    ],
  },
};
