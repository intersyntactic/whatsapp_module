/// The relay's two secrets. Each can be used for the one check it exists
/// for and has no way to be read back, so nothing in the relay can log,
/// print or forward one.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The Meta app's secret, which keys the HMAC in `X-Hub-Signature-256`.
final class MetaAppSecret {
  MetaAppSecret._(this._hmac);

  final Hmac _hmac;

  /// [raw], trimmed; null when nothing is left.
  static MetaAppSecret? parse(String raw) {
    final s = raw.trim();
    return s.isEmpty ? null : MetaAppSecret._(Hmac(sha256, utf8.encode(s)));
  }

  /// Whether [header] is `sha256=<hex>` of [body] under this secret. The
  /// digests are compared in constant time, on the raw bytes as they came.
  bool signed(List<int> body, String? header) {
    final presented = _hexDigest(header);
    if (presented == null) return false;
    final expected = _hmac.convert(body).bytes;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ presented[i];
    }
    return diff == 0;
  }

  /// The 32 bytes [header] names, or null unless it is exactly
  /// `sha256=` and 64 hex digits.
  static List<int>? _hexDigest(String? header) {
    const prefix = 'sha256=';
    if (header == null || !header.startsWith(prefix)) return null;
    final hex = header.substring(prefix.length);
    if (!_hex64.hasMatch(hex)) return null;
    return [
      for (var i = 0; i < 64; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }

  static final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  @override
  String toString() => 'MetaAppSecret(…)';
}

/// The token Meta echoes in the sign-up handshake, chosen when the
/// callback was set.
final class WebhookVerifyToken {
  WebhookVerifyToken._(this._bytes);

  final List<int> _bytes;

  /// [raw], trimmed; null when nothing is left.
  static WebhookVerifyToken? parse(String raw) {
    final s = raw.trim();
    return s.isEmpty ? null : WebhookVerifyToken._(utf8.encode(s));
  }

  /// Whether [given] is this token, compared in constant time over the
  /// token's length.
  bool matches(String? given) {
    if (given == null) return false;
    final g = utf8.encode(given);
    var diff = g.length ^ _bytes.length;
    for (var i = 0; i < _bytes.length; i++) {
      diff |= _bytes[i] ^ (i < g.length ? g[i] : 0);
    }
    return diff == 0;
  }

  @override
  String toString() => 'WebhookVerifyToken(…)';
}
