/// Run behind TLS (a reverse proxy): Meta calls only https. The callback is
/// `https://<host>/whatsapp/webhook`, set as the phone number's
/// `override_callback_uri`, so this number's webhooks come here and no
/// other number's change.
///
///   CREDENTIALS_DIRECTORY            from systemd's LoadCredential=; holds
///     meta-app-secret                  the Meta app's secret, which keys
///                                      X-Hub-Signature-256
///     whatsapp-verify-token            the token set with the callback
///                                    Both required; either missing aborts
///   WHATSAPP_PHONE_NUMBER_ID=…       the one business number taken, as
///                                    `GET /<WABA id>/phone_numbers` lists
///                                    it. Required; a non-id aborts
///   LOGBOOK_SOCKET=/run/...sock      the logbook's writer's Unix socket.
///                                    Required
///   PORT=8088                        optional; a non-port aborts
///   HOST=127.0.0.1                   optional; the address to bind
library;

import 'dart:async';
import 'dart:io';

import 'package:is_whatsapp_module/is_whatsapp_module.dart';

/// The source the relay's events are recorded under, which the module's
/// reading names as its own.
const _source = 'whatsapp';

Never _abort(String why) {
  stderr.writeln('abort: $why');
  exit(78);
}

Future<void> main() async {
  final env = Platform.environment;

  final credentials = env['CREDENTIALS_DIRECTORY'] ?? '';
  if (credentials.isEmpty) _abort('CREDENTIALS_DIRECTORY not set');
  String readCredential(String name) {
    try {
      return File('$credentials/$name').readAsStringSync();
    } on FileSystemException {
      _abort('no credential $name');
    }
  }

  final secret =
      MetaAppSecret.parse(readCredential('meta-app-secret')) ??
      _abort('credential meta-app-secret is empty');
  final verifyToken =
      WebhookVerifyToken.parse(readCredential('whatsapp-verify-token')) ??
      _abort('credential whatsapp-verify-token is empty');

  final rawPhone = env['WHATSAPP_PHONE_NUMBER_ID'] ?? '';
  final phone =
      PhoneNumberId.parse(rawPhone) ??
      _abort('WHATSAPP_PHONE_NUMBER_ID "$rawPhone" is not a phone number id');

  final logbookSocket = env['LOGBOOK_SOCKET'] ?? '';
  // A relay that can't record what arrives must not answer 200 to it. Not
  // checked for at boot: the writer may start after the relay, and until it
  // answers, every delivery gets a 500 and Meta sends it again.
  if (logbookSocket.isEmpty) _abort('LOGBOOK_SOCKET not set');

  final rawPort = env['PORT'];
  final port = rawPort == null || rawPort.isEmpty
      ? 8088
      : int.tryParse(rawPort);
  if (port == null || port < 1 || port > 65535) {
    _abort('PORT "$rawPort" is not a port number');
  }
  final host = switch (env['HOST']) {
    final h? when h.isNotEmpty => h,
    _ => '127.0.0.1',
  };
  final address =
      InternetAddress.tryParse(host) ?? _abort('HOST "$host" is not an IP');

  final relay = WhatsAppRelay(
    secret: secret,
    verifyToken: verifyToken,
    phoneNumberId: phone,
    record: (body) => recordEvent(logbookSocket, source: _source, bytes: body),
  );
  final server = await HttpServer.bind(address, port);
  stdout.writeln(
    'whatsapp relay for $phone listening on ${address.address}:${server.port}',
  );
  if (!address.isLoopback) {
    stderr.writeln(
      'warning: bound to ${address.address}, which serves plain HTTP; '
      'put TLS in front',
    );
  }
  await for (final req in server) {
    unawaited(relay.handle(req));
  }
}
