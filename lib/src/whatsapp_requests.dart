/// A message out through the Cloud API, as a [ProposedRequest]: described
/// for the web request driver to send, never sent here. The airlock grants
/// it under [whatsappSendPrefix], and the driver signs it with a
/// `bearer-token` sign-in pinned to the same prefix, so the token, which can
/// send from every number on the business account, reaches only this one.
///
/// A 200 from the endpoint means Meta accepted the message, not that anyone
/// got it: delivery and failure come later as statuses, which the relay
/// records.
library;

import 'dart:convert';

import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show PinnedBodyFields, RepliesWithPinnedBodyFields;
import 'package:is_web_request_vocabulary/is_web_request_vocabulary.dart'
    show Method, ProposedRequest;
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart' show SignIn;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, PathPrefix, WebPath;

import 'whatsapp_ids.dart';

/// The Graph API version every request names. Moving it means moving the
/// sign-in's pinned prefix with it.
const graphVersion = 'v27.0';

final _graph = Origin.parse('https://graph.facebook.com')!;

/// What a trajectory's rule grants to send from [from]: everything under
/// `/v27.0/<phone number id>/`. It does not cover `/v27.0/<phone number id>`
/// itself, where the number's webhook is set.
PathPrefix whatsappSendPrefix(PhoneNumberId from) =>
    PathPrefix.parse('/$graphVersion/${from.value}/')!;

/// [text] from [from] to [to], under [signIn].
ProposedRequest whatsappTextRequest({
  required PhoneNumberId from,
  required WhatsAppRecipient to,
  required WhatsAppText text,
  required SignIn signIn,
}) => ProposedRequest(
  _graph,
  method: Method.post,
  path: _messagesPath(from),
  signIn: signIn,
  headers: const {'content-type': 'application/json; charset=utf-8'},
  body: jsonEncode({
    ..._chatFields(to),
    'type': 'text',
    'text': {'body': text.value},
  }),
);

/// Where replies in a chat with [to] go: [from]'s messages path, with a
/// body naming exactly [to] and carrying nothing but a message besides.
/// Any other top-level field is refused, so a way of naming a recipient
/// Meta adds later, or `recipient` (a user id, which Meta ranks below
/// `to`), can't send a reply elsewhere.
RepliesWithPinnedBodyFields whatsappReplyEndpoint({
  required PhoneNumberId from,
  required WhatsAppRecipient to,
}) => RepliesWithPinnedBodyFields.at(
  origin: _graph,
  path: _messagesPath(from),
  pinned: PinnedBodyFields.allowingOnly(
    _chatFields(to),
    otherFields: _messageFields,
  )!,
)!;

/// The fields a text message adds to [_chatFields]. A new kind of message
/// adds its fields here, or its replies are refused.
const _messageFields = {'type', 'text'};

/// The fields that name the chat a message goes to.
Map<String, String> _chatFields(WhatsAppRecipient to) => {
  'messaging_product': 'whatsapp',
  'recipient_type': to._kind,
  'to': to._id,
};

WebPath _messagesPath(PhoneNumberId from) =>
    WebPath.parse('/$graphVersion/${from.value}/messages')!;

/// Who a message goes to: one person, or a group.
sealed class WhatsAppRecipient {
  const WhatsAppRecipient();

  factory WhatsAppRecipient.person(WhatsAppPhoneNumber number) = _Person;
  factory WhatsAppRecipient.group(GroupId group) = _Group;

  String get _kind;
  String get _id;
}

final class _Person extends WhatsAppRecipient {
  const _Person(this.number);
  final WhatsAppPhoneNumber number;
  @override
  String get _kind => 'individual';
  @override
  String get _id => number.value;
}

final class _Group extends WhatsAppRecipient {
  const _Group(this.group);
  final GroupId group;
  @override
  String get _kind => 'group';
  @override
  String get _id => group.value;
}

/// A phone number as Meta writes a `wa_id`: country code and number, digits
/// only.
final class WhatsAppPhoneNumber {
  const WhatsAppPhoneNumber._(this.value);

  final String value;

  static WhatsAppPhoneNumber? parse(String s) =>
      _digits.hasMatch(s) ? WhatsAppPhoneNumber._(s) : null;

  static final _digits = RegExp(r'^[1-9][0-9]{5,14}$');

  @override
  String toString() => value;
}

/// The body of one text message: not blank, and at most [maxCharacters]
/// characters, Meta's limit. Whether Meta counts characters or UTF-16 code
/// units is unmeasured; this counts characters, and an emoji outside the
/// basic plane is one.
final class WhatsAppText {
  const WhatsAppText._(this.value);

  static const maxCharacters = 4096;

  final String value;

  static WhatsAppText? parse(String s) =>
      s.trim().isEmpty || s.runes.length > maxCharacters
      ? null
      : WhatsAppText._(s);

  /// [s] in pieces that each fit, cut at the last whitespace before the
  /// limit when there is one past halfway, and at the limit otherwise.
  /// Pieces are trimmed; blank [s] gives none.
  static List<WhatsAppText> split(String s) {
    final pieces = <WhatsAppText>[];
    var rest = s.trim().runes.toList();
    while (rest.length > maxCharacters) {
      var cut = maxCharacters;
      for (var i = maxCharacters; i > maxCharacters ~/ 2; i--) {
        if (_isSpace(rest[i])) {
          cut = i;
          break;
        }
      }
      pieces.add(WhatsAppText._(String.fromCharCodes(rest, 0, cut).trim()));
      rest = String.fromCharCodes(rest, cut).trim().runes.toList();
    }
    if (rest.isNotEmpty) pieces.add(WhatsAppText._(String.fromCharCodes(rest)));
    return pieces;
  }

  static bool _isSpace(int rune) => String.fromCharCode(rune).trim().isEmpty;

  @override
  String toString() => value;
}
