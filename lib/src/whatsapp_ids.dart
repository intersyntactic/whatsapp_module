/// The ids Meta's webhooks carry, each read once at the wire into a type
/// that only a valid value can be.
library;

/// A business phone number's id on the Cloud API: digits, never the phone
/// number itself. One WhatsApp business account holds several, and the
/// webhook's `metadata.phone_number_id` says which one a change is for.
final class PhoneNumberId {
  const PhoneNumberId._(this.value);

  final String value;

  static PhoneNumberId? parse(String s) =>
      _digits.hasMatch(s) ? PhoneNumberId._(s) : null;

  static final _digits = RegExp(r'^[0-9]{5,30}$');

  @override
  bool operator ==(Object other) =>
      other is PhoneNumberId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A message's id, `wamid.` and then Meta's base64: the same for a message
/// and every status about it, and for a redelivery of either.
final class WhatsAppMessageId {
  const WhatsAppMessageId._(this.value);

  final String value;

  static WhatsAppMessageId? parse(String s) =>
      _id.hasMatch(s) ? WhatsAppMessageId._(s) : null;

  static final _id = RegExp(r'^wamid\.[A-Za-z0-9+/=_-]{1,256}$');

  @override
  bool operator ==(Object other) =>
      other is WhatsAppMessageId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A group's id, as Meta names it in `group_id` and as `to` when the
/// business sends to the group.
final class GroupId {
  const GroupId._(this.value);

  final String value;

  static GroupId? parse(String s) => _id.hasMatch(s) ? GroupId._(s) : null;

  static final _id = RegExp(r'^[A-Za-z0-9+/=_-]{1,256}$');

  @override
  bool operator ==(Object other) => other is GroupId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A WhatsApp user's business-scoped user id (`user_id`, `from_user_id`):
/// who they are to this business, and present even when Meta withholds
/// their phone number because they use a username.
final class WhatsAppUserId {
  const WhatsAppUserId._(this.value);

  final String value;

  static WhatsAppUserId? parse(String s) =>
      _id.hasMatch(s) ? WhatsAppUserId._(s) : null;

  static final _id = RegExp(r'^[\x21-\x7e]{1,128}$');

  @override
  bool operator ==(Object other) =>
      other is WhatsAppUserId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
