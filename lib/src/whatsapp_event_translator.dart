/// The Cloud route's events in the docking station's terms: each entry the
/// relay recorded, one item each, as a [TranslatedEvent].
///
/// What is admitted so far: a text message with an author Meta names by
/// user id, in a group or a one-to-one chat with the business number, with
/// replies confined to that chat by [whatsappReplyEndpoint]. Statuses,
/// group changes and every other message type are [NothingToAdmit] until a
/// reading needs them.
library;

import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show
        ConversationKind,
        KnownAuthor,
        Quote,
        QuotedAuthor,
        SourceMessageId,
        UnknownAuthor,
        UserSaid;
import 'package:is_shapes/is_shapes.dart' show ActorId;

import 'whatsapp_delivery.dart';
import 'whatsapp_ids.dart';
import 'whatsapp_requests.dart';

/// Who wrote each message translated so far, so a reply can name who it
/// quotes. Never changed once made: [said] gives a new one.
final class WhatsAppMessageAuthors {
  const WhatsAppMessageAuthors._(this._authors);

  static const none = WhatsAppMessageAuthors._({});

  final Map<SourceMessageId, ActorId> _authors;

  ActorId? of(SourceMessageId message) => _authors[message];

  /// These authors, and [author] as the one who said [message].
  WhatsAppMessageAuthors said(SourceMessageId message, ActorId author) =>
      WhatsAppMessageAuthors._(
        Map.unmodifiable({..._authors, message: author}),
      );
}

final class WhatsAppEventTranslator
    implements TranslatesRelayedEvents<WhatsAppMessageAuthors> {
  const WhatsAppEventTranslator();

  /// The source the relay records the Cloud route's events under.
  static final whatsapp = RelayedEventSource.parse('whatsapp')!;

  @override
  RelayedEventSource get source => whatsapp;

  @override
  WhatsAppMessageAuthors get start => WhatsAppMessageAuthors.none;

  @override
  (WhatsAppMessageAuthors, TranslatedEvent) step(
    WhatsAppMessageAuthors state,
    RelayedEvent event,
  ) {
    final delivery = WhatsAppDelivery.parse(event.bytes);
    if (delivery == null) return (state, const NothingToAdmit());
    final number = delivery.phoneNumberIds.singleOrNull;
    final message = delivery.messages.singleOrNull;
    if (number == null || message == null) {
      return (state, const NothingToAdmit());
    }
    final said = _messageSaid(state, number, message);
    if (said == null) return (state, const NothingToAdmit());
    return (state.said(said.message, said.from), said);
  }

  static MessageSaid? _messageSaid(
    WhatsAppMessageAuthors state,
    PhoneNumberId number,
    InboundMessage m,
  ) {
    final from = m.from;
    final text = m.text;
    if (from == null || text == null) return null;
    final author = whatsAppActor(from);
    final source = SourceMessageId.parse(m.id.value);
    final key = EventKey.parse(m.id.value);
    final (address, kind, forTheAgent, replyTo) = switch (m.group) {
      final group? => (
        groupAddress(group),
        ConversationKind.groupChat,
        // A group delivers everyone's messages, and Meta's group webhook
        // carries no mentions, so whether this one is for the agent can't
        // be read from it.
        WhetherForTheAgent.notKnown,
        WhatsAppRecipient.group(group),
      ),
      null => (
        chatAddress(number, from),
        ConversationKind.oneToOne,
        WhetherForTheAgent.everyMessageHereIsForTheAgent,
        switch (WhatsAppPhoneNumber.parse(m.fromPhone ?? '')) {
          final phone? => WhatsAppRecipient.person(phone),
          // Someone who hides their number behind a username: Meta takes
          // a user id as `recipient`, but no send has been seen to arrive.
          null => null,
        },
      ),
    };
    if (author == null || source == null || key == null || address == null) {
      return null;
    }
    return MessageSaid(
      addressInExternalSystem: address,
      containingAddress: null,
      addressedTo: businessNumberActor(number),
      replyEndpoint: switch (replyTo) {
        final to? => whatsappReplyEndpoint(from: number, to: to),
        null => null,
      },
      conversationKind: kind,
      forTheAgent: forTheAgent,
      key: key,
      node: UserSaid(
        author: author,
        source: source,
        text: text,
        quotes: switch (m.replyTo) {
          final quoted? => _quote(state, quoted),
          null => null,
        },
      ),
    );
  }

  static Quote? _quote(WhatsAppMessageAuthors state, WhatsAppMessageId id) {
    final source = SourceMessageId.parse(id.value);
    if (source == null) return null;
    final QuotedAuthor author = switch (state.of(source)) {
      final actor? => KnownAuthor(actor),
      null => const UnknownAuthor(null),
    };
    return Quote(source: source, author: author);
  }
}

/// A person, by the business-scoped user id Meta names them by.
ActorId? whatsAppActor(WhatsAppUserId user) =>
    ActorId.parse('whatsapp:user:${user.value}');

/// The business number itself, as what a message was sent to.
ActorId? businessNumberActor(PhoneNumberId number) =>
    ActorId.parse('whatsapp:number:${number.value}');

/// A group, which is the same group whichever number is in it.
AddressInExternalSystem? groupAddress(GroupId group) =>
    AddressInExternalSystem.parse('whatsapp:group:${group.value}');

/// A one-to-one chat: one person and one business number.
AddressInExternalSystem? chatAddress(
  PhoneNumberId number,
  WhatsAppUserId user,
) => AddressInExternalSystem.parse(
  'whatsapp:chat:${number.value}:${user.value}',
);
