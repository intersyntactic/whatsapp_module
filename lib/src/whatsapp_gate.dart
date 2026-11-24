/// What the relay does with each request, decided without a socket, a clock
/// or Meta, so every guard is a test.
///
/// Two requests come: the sign-up handshake ([answerHandshake]) when the
/// callback is set, and a delivery ([decideDelivery]) for every change after.
library;

import 'meta_secrets.dart';
import 'whatsapp_delivery.dart';
import 'whatsapp_ids.dart';

/// What to answer Meta's `GET ?hub.mode=subscribe&hub.verify_token=…
/// &hub.challenge=…`.
sealed class HandshakeAnswer {
  const HandshakeAnswer();
}

/// The token matched: answer 200 with [challenge] as plain text.
final class HandshakeAccepted extends HandshakeAnswer {
  const HandshakeAccepted(this.challenge);
  final String challenge;
}

/// Answer 403, with nothing that says why.
final class HandshakeRefused extends HandshakeAnswer {
  const HandshakeRefused();
}

/// The handshake, from the request's decoded [query]. A challenge echoes
/// only when [token] matches, since an endpoint that echoes any challenge
/// can be signed up to someone else's app. The challenge must be a short
/// plain word: Meta's is a number, and nothing else is echoed back.
HandshakeAnswer answerHandshake({
  required Map<String, String> query,
  required WebhookVerifyToken token,
}) {
  // wire-ok: Meta's handshake mode, checked once at the wire.
  final subscribing = query['hub.mode'] == 'subscribe';
  final challenge = query['hub.challenge'] ?? '';
  final tokenMatches = token.matches(query['hub.verify_token']);
  if (subscribing && tokenMatches && _challenge.hasMatch(challenge)) {
    return HandshakeAccepted(challenge);
  }
  return const HandshakeRefused();
}

final _challenge = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// What "seen before" compares: one message, or one state of one message
/// for one participant. A body is keyed by what it carries, not by its
/// bytes, since Meta may batch a retry with something new.
final class RepeatKey {
  const RepeatKey._(this._value);

  final String _value;

  factory RepeatKey.message(WhatsAppMessageId id) =>
      RepeatKey._('message:${id.value}');

  factory RepeatKey.status(DeliveryStatus s) => RepeatKey._(
    'status:${s.message.value}:${s.stateAsSent}:${s.participant?.value ?? '-'}',
  );

  @override
  bool operator ==(Object other) =>
      other is RepeatKey && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => _value;
}

/// What to do with one POST.
sealed class DeliveryDecision {
  const DeliveryDecision(this.reason);

  /// For the log: ids and outcomes, never what anyone wrote.
  final String reason;
}

/// Authentic, for this number, with something new: record it, and answer
/// 200 once it is recorded. [keys] go into the seen set.
final class DeliveryTaken extends DeliveryDecision {
  const DeliveryTaken(this.delivery, this.keys) : super('taken');
  final WhatsAppDelivery delivery;
  final Set<RepeatKey> keys;
}

/// Authentic, and everything in it was taken already: answer 200, record
/// nothing.
final class DeliveryRepeated extends DeliveryDecision {
  const DeliveryRepeated() : super('repeat');
}

/// Authentic, but for another of the business account's numbers: answer
/// 200 so Meta stops sending it, and record nothing. Only a callback set
/// wrongly sends one here.
final class DeliveryNotForThisNumber extends DeliveryDecision {
  DeliveryNotForThisNumber(this.others)
    : super('for phone number ${others.join(',')}, not this relay\'s');
  final Set<PhoneNumberId> others;
}

/// Answer [status] and record nothing.
final class DeliveryRefused extends DeliveryDecision {
  const DeliveryRefused(this.status, super.reason);
  final int status;
}

/// One POST's [body], under its `X-Hub-Signature-256` [signatureHeader].
///
/// The signature is checked on the raw bytes before anything reads them as
/// JSON. A signature proves only that Meta sent it for this app, and the app
/// serves the account's other numbers too, so a body is held to
/// [phoneNumberId] next. Then [hasSeen] drops what was taken already.
/// Meta's header carries no signed time, so a body captured once stays
/// validly signed: the repeat filter here, and the docking station's event
/// keys after it, are what keep a replay from counting twice.
DeliveryDecision decideDelivery({
  required MetaAppSecret secret,
  required PhoneNumberId phoneNumberId,
  required List<int> body,
  required String? signatureHeader,
  required bool Function(RepeatKey key) hasSeen,
}) {
  if (!secret.signed(body, signatureHeader)) {
    return const DeliveryRefused(403, 'signature does not match');
  }
  final delivery = WhatsAppDelivery.parse(body);
  if (delivery == null) {
    return const DeliveryRefused(400, 'signed, but not a webhook body');
  }
  final others = delivery.phoneNumberIds.difference({phoneNumberId});
  if (others.isNotEmpty) return DeliveryNotForThisNumber(others);
  final keys = {
    for (final m in delivery.messages) RepeatKey.message(m.id),
    for (final s in delivery.statuses) RepeatKey.status(s),
  };
  // A body with no keys, such as a group change, is always taken: recording
  // it twice costs a duplicate the reading drops, and dropping it loses it.
  if (keys.isNotEmpty && keys.every(hasSeen)) return const DeliveryRepeated();
  return DeliveryTaken(delivery, keys);
}
