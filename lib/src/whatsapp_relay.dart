/// The HTTP front of the WhatsApp module: the one callback Meta calls for
/// this business number.
///
/// `GET` is the sign-up handshake. `POST` is a delivery: its body is read
/// under a cap and a deadline, checked by [decideDelivery], recorded one
/// item to an entry, and only then answered 200, so a 200 means "in the
/// logbook". Nothing is done
/// with a delivery here beyond recording it: the docking station reads it
/// from the logbook.
///
/// The log gets one line per request: the status and the gate's reason.
/// Never a query string, which carries the verify token, and never a body.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'meta_secrets.dart';
import 'record_event.dart';
import 'whatsapp_gate.dart';
import 'whatsapp_ids.dart';

final class WhatsAppRelay {
  WhatsAppRelay({
    required this.secret,
    required this.verifyToken,
    required this.phoneNumberId,
    required this.record,
    DateTime Function()? now,
    this.bodyTimeout = const Duration(seconds: 10),
    this.maxBodyBytes = 1024 * 1024,
    this.seenFor = const Duration(hours: 24),
    this.seenMax = 20000,
    this.log = _stderr,
  }) : _now = now ?? DateTime.now;

  /// The callback's path: the relay's address plus this is the
  /// `override_callback_uri` set on the phone number.
  static const path = '/whatsapp/webhook';

  final MetaAppSecret secret;
  final WebhookVerifyToken verifyToken;

  /// The one business number this relay takes deliveries for.
  final PhoneNumberId phoneNumberId;

  /// Records one item of a delivery taken, as
  /// [WhatsAppDelivery.oneItemBodies] cuts it, before Meta gets a response:
  /// in the relay, [recordEvent]. Only every item [Recorded] gets a 200;
  /// anything else, or a throw, gets a 500 and the delivery is forgotten as
  /// seen, so Meta's retry is taken.
  final Future<RecordAnswer> Function(Uint8List item) record;

  final Duration bodyTimeout;
  final int maxBodyBytes;

  /// How long a key is remembered. Meta retries a failed delivery for up
  /// to a day or so; past this a retry is recorded again and the reading's
  /// keys drop it.
  final Duration seenFor;

  /// A ceiling on the seen set, so a flood cannot grow it without bound.
  final int seenMax;

  final void Function(String line) log;

  final DateTime Function() _now;

  /// Seen key to first sight, oldest first.
  final LinkedHashMap<RepeatKey, DateTime> _seen = LinkedHashMap();

  Future<void> handle(HttpRequest req) async {
    try {
      if (req.uri.path != path) {
        await _refuseUnread(req, HttpStatus.notFound);
        return;
      }
      // wire-ok: the HTTP method, checked against the two we accept.
      switch (req.method) {
        case 'GET':
          await _handshake(req);
        case 'POST':
          await _delivery(req);
        default:
          await _refuseUnread(req, HttpStatus.methodNotAllowed);
      }
    } on Exception catch (e) {
      log('whatsapp relay: ${e.runtimeType}');
      try {
        await _end(req, HttpStatus.internalServerError);
      } on Exception {
        // The response was already under way; there is no one left to tell.
      }
    }
  }

  Future<void> _handshake(HttpRequest req) async {
    switch (answerHandshake(
      query: req.uri.queryParameters,
      token: verifyToken,
    )) {
      case HandshakeAccepted(:final challenge):
        log('whatsapp relay: 200 handshake');
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text
          ..write(challenge);
        await req.response.close();
      case HandshakeRefused():
        log('whatsapp relay: 403 handshake refused');
        await _refuseUnread(req, HttpStatus.forbidden);
    }
  }

  Future<void> _delivery(HttpRequest req) async {
    if (req.contentLength > maxBodyBytes) {
      return _refuseUnread(req, HttpStatus.requestEntityTooLarge);
    }
    // No signature, no body read: a sender without the header is turned away
    // at the door.
    final signature = req.headers.value('x-hub-signature-256');
    if (signature == null) {
      log('whatsapp relay: 403 no signature');
      return _refuseUnread(req, HttpStatus.forbidden);
    }

    final body = BytesBuilder(copy: false);
    var tooLarge = false;
    try {
      // One deadline for the whole body, not a gap between chunks: a sender
      // trickling a byte at a time must not hold the connection open.
      await () async {
        await for (final chunk in req) {
          if (body.length + chunk.length > maxBodyBytes) {
            tooLarge = true;
            return;
          }
          body.add(chunk);
        }
      }().timeout(bodyTimeout);
    } on TimeoutException {
      log('whatsapp relay: 408 body too slow');
      return _refuseUnread(req, HttpStatus.requestTimeout);
    }
    if (tooLarge) return _refuseUnread(req, HttpStatus.requestEntityTooLarge);
    final bytes = body.takeBytes();

    final now = _now();
    // No await from here to the keys being marked: two copies of one
    // delivery arriving together cannot both get past hasSeen.
    final d = decideDelivery(
      secret: secret,
      phoneNumberId: phoneNumberId,
      body: bytes,
      signatureHeader: signature,
      hasSeen: _hasSeen,
    );
    switch (d) {
      case DeliveryRefused(:final status):
        log('whatsapp relay: $status ${d.reason}');
        return _refuseUnread(req, status);
      case DeliveryRepeated() || DeliveryNotForThisNumber():
        log('whatsapp relay: 200 ${d.reason}');
        return _end(req, HttpStatus.ok);
      case DeliveryTaken(:final keys):
        for (final k in keys) {
          _markSeen(k, now);
        }
        final items = d.delivery.oneItemBodies;
        RecordAnswer answer = const Recorded('-');
        // In order, stopping at the first not recorded: Meta's retry sends
        // the whole body again, and the docking station's keys drop the
        // items recorded before the stop.
        for (final item in items) {
          try {
            answer = await record(item);
          } on Object catch (e) {
            answer = RecordUnanswered('${e.runtimeType}');
          }
          if (answer is! Recorded) break;
        }
        final why = switch (answer) {
          Recorded() => null,
          RecordFailed(:final why) => 'record failed partway: $why',
          RecordRefused(:final why) => 'refused by the logbook: $why',
          RecordUnanswered(:final why) => 'not recorded: $why',
        };
        if (why != null) {
          // Unrecorded is not taken: forget the keys, so Meta's retry of the
          // 500 is taken and recorded then.
          keys.forEach(_seen.remove);
          log('whatsapp relay: 500 $why');
          return _end(req, HttpStatus.internalServerError);
        }
        log(
          'whatsapp relay: 200 ${d.reason} ${keys.length} key(s), '
          '${items.length} entr${items.length == 1 ? 'y' : 'ies'}',
        );
        return _end(req, HttpStatus.ok);
    }
  }

  bool _hasSeen(RepeatKey key) {
    final at = _seen[key];
    if (at == null) return false;
    if (_now().difference(at) > seenFor) {
      _seen.remove(key);
      return false;
    }
    return true;
  }

  void _markSeen(RepeatKey key, DateTime at) {
    _seen.remove(key);
    _seen[key] = at;
    while (_seen.length > seenMax) {
      _seen.remove(_seen.keys.first);
    }
    final cutoff = at.subtract(seenFor);
    while (_seen.isNotEmpty && _seen.values.first.isBefore(cutoff)) {
      _seen.remove(_seen.keys.first);
    }
  }

  static Future<void> _end(HttpRequest req, int status) async {
    req.response.statusCode = status;
    await req.response.close();
  }

  /// Responds with [status] and drops the connection, leaving the rest of
  /// the body unread: dart:io's `response.close()` would read it all first.
  static Future<void> _refuseUnread(HttpRequest req, int status) async {
    req.response
      ..statusCode = status
      ..persistentConnection = false
      ..contentLength = 0;
    final socket = await req.response.detachSocket();
    await socket.flush();
    socket.destroy();
  }

  static void _stderr(String line) => stderr.writeln(line);
}
