/// The WhatsApp module: what people say in a WhatsApp group, taken in from
/// Meta's webhooks, and the way back out as web requests.
///
/// The way in: [WhatsAppRelay], the endpoint Meta posts to, which checks each
/// delivery with [decideDelivery] and answers the sign-up handshake with
/// [answerHandshake], and [recordEvent], which records each delivery taken
/// with the logbook's one writer, one item to an entry. The docking station
/// reads those entries back through [WhatsAppEventTranslator].
library;

export 'src/meta_secrets.dart';
export 'src/record_event.dart';
export 'src/whatsapp_delivery.dart';
export 'src/whatsapp_event_translator.dart';
export 'src/whatsapp_gate.dart';
export 'src/whatsapp_ids.dart';
export 'src/whatsapp_relay.dart';
export 'src/whatsapp_requests.dart';
