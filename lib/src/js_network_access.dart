// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// The network that JavaScript may reach through `fetch`, granted by
/// [JsRuntimeOptions.network].
///
/// A URL is allowed when its scheme is `http` or `https`, its host is one of
/// [allowedHosts] and [allowUrl], when given, agrees. The check runs for the
/// URL of a request and again for every redirect.
///
/// ```dart
/// final options = JsRuntimeOptions(
///   network: JsNetworkAccess(
///     allowedHosts: {'api.example.com'},
///     allowUrl: (url) => url.path.startsWith('/v1/'),
///   ),
/// );
/// ```
final class JsNetworkAccess {
  /// Creates a network grant.
  ///
  /// - [allowedHosts] the hosts JavaScript may reach: `example.com`,
  ///   `localhost:8080` for one port only, `*.example.com` for the
  ///   subdomains, `*` for every host
  /// - [allowUrl] a further check of every URL, e.g. of its path
  /// - [maxRedirects] the redirects a request follows at most
  const JsNetworkAccess({
    required this.allowedHosts,
    this.allowUrl,
    this.maxRedirects = 5,
  });

  /// Creates an example grant for tests and docs.
  factory JsNetworkAccess.example({Set<String>? allowedHosts}) =>
      JsNetworkAccess(allowedHosts: allowedHosts ?? const {'example.com'});

  // ...........................................................................
  /// Whether JavaScript may request [url].
  bool allows(Uri url) {
    if (url.scheme != 'http' && url.scheme != 'https') return false;
    if (!allowedHosts.any((host) => _matches(host, url))) return false;
    return allowUrl?.call(url) ?? true;
  }

  // ...........................................................................
  /// The hosts that JavaScript may reach.
  final Set<String> allowedHosts;

  /// A further check of every URL; null to allow every URL of
  /// [allowedHosts].
  final bool Function(Uri url)? allowUrl;

  /// The redirects that a request follows at most.
  final int maxRedirects;

  // ...........................................................................
  static bool _matches(String pattern, Uri url) {
    if (pattern == '*') return true;
    final host = url.host.toLowerCase();
    final colon = pattern.lastIndexOf(':');
    final hasPort =
        colon > 0 && int.tryParse(pattern.substring(colon + 1)) != null;
    final name = (hasPort ? pattern.substring(0, colon) : pattern)
        .toLowerCase();
    if (hasPort && int.parse(pattern.substring(colon + 1)) != url.port) {
      return false;
    }
    if (name.startsWith('*.')) return host.endsWith(name.substring(1));
    return host == name;
  }
}
