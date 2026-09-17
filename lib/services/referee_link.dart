import 'package:flutter/foundation.dart';

/// A parsed referee deep link: the capability token and the API base.
typedef RefereeLink = ({String token, Uri baseUri});

/// Parse an HTTPS referee link (`https://<scoreboard host>/r/<token>`) or the
/// custom `rcjrefmate://r/<token>` link. Returns null for anything else.
///
/// In debug builds the custom link accepts `?base_url=http://<local host>`
/// (loopback, the emulator alias or an RFC 1918 address) for mock servers.
RefereeLink? parseRefereeLink(Uri uri, {required Uri defaultBase}) {
  if (uri.scheme == 'https') {
    final segments = uri.pathSegments;
    if (segments.length < 2 || segments.first != 'r') return null;
    if (uri.host.toLowerCase() != defaultBase.host.toLowerCase()) return null;
    final token = Uri.decodeComponent(segments[1]).trim();
    if (token.isEmpty) return null;
    return (
      token: token,
      baseUri: Uri(
          scheme: 'https', host: uri.host, port: uri.hasPort ? uri.port : null),
    );
  }
  if (uri.scheme != 'rcjrefmate' ||
      uri.host != 'r' ||
      uri.pathSegments.isEmpty) {
    return null;
  }
  final token = Uri.decodeComponent(uri.pathSegments.first).trim();
  if (token.isEmpty) return null;
  return (token: token, baseUri: _debugBaseOverride(uri) ?? defaultBase);
}

Uri? _debugBaseOverride(Uri uri) {
  if (!kDebugMode) return null;
  final raw = uri.queryParameters['base_url']?.trim();
  if (raw == null || raw.isEmpty) return null;
  final base = Uri.tryParse(raw);
  if (base == null ||
      base.host.isEmpty ||
      (base.scheme != 'http' && base.scheme != 'https') ||
      !_isLocalHost(base.host.toLowerCase())) {
    return null;
  }
  return base.replace(path: '', query: null, fragment: null);
}

bool _isLocalHost(String host) {
  const loopback = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};
  if (loopback.contains(host)) return true;
  final octets = host.split('.').map(int.tryParse).toList();
  if (octets.length != 4 || octets.any((o) => o == null || o < 0 || o > 255)) {
    return false;
  }
  final [a, b, _, _] = octets.cast<int>();
  return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
}
