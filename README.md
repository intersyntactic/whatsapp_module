# is_whatsapp_module

The WhatsApp module for intersyntactic: what people say to Claude's WhatsApp
number, taken in as events in the logbook, and the docking station's reading
of them.

## Status

The transport is moving. This package began as a relay for Meta's Cloud
API, and that relay is here, built and tested. But the Cloud API's Groups
API needs an Official Business Account, so the group chat this module exists
for will instead run over a WhatsApp linked device:
[whatsapp_linked_device](https://github.com/intersyntactic/whatsapp_linked_device),
a Dart client of WhatsApp's multi-device protocol, where Claude's number is an
ordinary member of real groups.

What carries over to the linked device: recording each event to the logbook
(`lib/src/record_event.dart`), dropping repeats by message id, and the reading
the docking station will get. What stays specific to the Cloud API: the
webhook relay, its signature check and its sign-up handshake.

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
