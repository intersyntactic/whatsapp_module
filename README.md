# is_whatsapp_module

The WhatsApp module for intersyntactic: what people say to Claude's WhatsApp
number, taken in as events in the logbook, and the docking station's reading
of them.

## Status

WhatsApp reaches intersyntactic two ways, and this module serves both.

- **The Cloud API**, Meta's Business API. Messages come in through the relay
  here. Replies go out as web requests (`lib/src/whatsapp_requests.dart`)
  that the airlock grants and the web request driver signs with a
  `bearer-token` sign-in. Its Groups API needs an Official Business Account,
  so without one this route serves one-to-one chats.
- **A linked device**,
  [whatsapp_linked_device](https://github.com/intersyntactic/whatsapp_linked_device):
  a Dart client of WhatsApp's multi-device protocol, where Claude's number
  is an ordinary member of real groups. It holds its own long-lived session
  and is its own driver, so its messages neither come through the relay
  here nor go out through the web request driver.

What both share: recording each event to the logbook
(`lib/src/record_event.dart`), dropping repeats by message id, and the
translator the docking station will get (`WhatsAppEventTranslator`, still to
come, against `is_docking_station_api` 0.4.0).

## Sending through the Cloud API

`whatsappTextRequest` describes one text message as a `ProposedRequest`; it
sends nothing. A trajectory's rule grants it under
`whatsappSendPrefix(<phone number id>)`, which is `/v27.0/<id>/`, and the
sign-in's `pathPrefixes` pin the token to the same prefix. The token can send
from every number on the business account, and the pin is what holds it to
this one. The prefix does not cover `/v27.0/<id>` itself, where the number's
webhook is set.

Text over Meta's 4,096-character limit is split with `WhatsAppText.split`,
at whitespace where it can be, never through a character.

## The Cloud API relay

```
Meta ──POST (X-Hub-Signature-256)──▶ relay ──event, byte for byte──▶ logbook
          GET  (hub.* handshake)       │ checks the signature on the raw
                                       │ bytes, holds the body to one phone
                                       │ number, drops repeats by key,
                                       │ answers 200 only once recorded
```

- **The signature proves the app, not the number.** One Meta app serves every
  number on the business account, so after the HMAC check each `messages`
  change is held to `WHATSAPP_PHONE_NUMBER_ID`.
- **Meta's signature carries no time.** A captured body stays validly signed
  for good, so the repeat filter here, and the docking station's event keys
  after it, keep a replay from counting twice.
- **Repeats are keyed by what a body carries:** a message by its id, a status
  by its message, state and participant (a group sends `delivered` and `read`
  once per participant).
- **Accepted is not delivered.** Statuses are recorded as events like
  messages.
- **The secrets can't be read back.** `MetaAppSecret` and
  `WebhookVerifyToken` each do their one check and have no getter, and the
  relay logs no query string, so neither spelling of the verify token
  (`hub.verify_token`, `hub_verify_token`) reaches a log.

### Running it

```
CREDENTIALS_DIRECTORY=<holds meta-app-secret and whatsapp-verify-token> \
WHATSAPP_PHONE_NUMBER_ID=<from GET /<WABA id>/phone_numbers> \
LOGBOOK_SOCKET=<the logbook writer's Unix socket> \
  dart run bin/whatsapp_relay.dart
```

It listens on `127.0.0.1:8088` for a TLS proxy in front. The callback is
`https://<host>/whatsapp/webhook`, set as the phone number's
`override_callback_uri`.

## Tests

```
dart pub get
dart analyze --fatal-infos
dart test
```

Each guard is mutation-tested: deleting it alone turns a test red.
