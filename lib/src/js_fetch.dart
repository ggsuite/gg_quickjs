// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'js_exception.dart';
import 'js_network_access.dart';
import 'js_runtime.dart';

// .............................................................................
/// Installs the global `fetch` of [runtime] on a Dart [HttpClient] that
/// reaches only what [access] allows, checked for the request and for every
/// redirect; returns the function that closes the client.
///
/// `fetch(url, {method, headers, body})` resolves to an object with
/// `status`, `statusText`, `ok`, `url`, `redirected`, `headers.get(name)`,
/// `text()`, `json()`, `arrayBuffer()` and `bytes()`.
void Function() installJsFetch(JsRuntime runtime, JsNetworkAccess access) {
  final client = HttpClient();
  final install =
      runtime.evaluateHandle(_source, sourceUrl: '<gg_quickjs>') as JsFunction;
  try {
    install([
      (List<Object?> arguments) => _fetch(
        client,
        access,
        arguments[0]! as String,
        arguments[1]! as Map<String, Object?>,
      ),
    ]);
  } finally {
    install.dispose();
  }
  return () => client.close(force: true);
}

// Requests [url] and follows the redirects that [access] allows.
Future<Map<String, Object?>> _fetch(
  HttpClient client,
  JsNetworkAccess access,
  String url,
  Map<String, Object?> init,
) async {
  var uri = Uri.parse(url);
  var method = init['method']! as String;
  final headers = (init['headers']! as Map<Object?, Object?>).map(
    (key, value) => MapEntry('$key', '$value'),
  );
  var body = init['body'];
  for (var redirects = 0; ; redirects++) {
    if (!access.allows(uri)) {
      throw JsTypeError(message: 'fetch: access to $uri is not allowed');
    }
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (body is String) request.write(body);
    if (body is Uint8List) request.add(body);
    final response = await request.close();
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (_redirects.contains(response.statusCode) && location != null) {
      await response.drain<void>();
      if (redirects == access.maxRedirects) {
        throw JsTypeError(message: 'fetch: too many redirects for $url');
      }
      uri = uri.resolve(location);
      if (response.statusCode == HttpStatus.seeOther ||
          (method == 'POST' && response.statusCode < 307)) {
        method = 'GET';
        body = null;
      }
      continue;
    }
    final bytes = await response.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, chunk) => builder..add(chunk),
    );
    final data = bytes.takeBytes();
    final responseHeaders = <String, Object?>{};
    response.headers.forEach(
      (name, values) => responseHeaders[name.toLowerCase()] = values.join(', '),
    );
    return {
      'status': response.statusCode,
      'statusText': response.reasonPhrase,
      'url': uri.toString(),
      'redirected': redirects > 0,
      'headers': responseHeaders,
      'body': data,
      'text': utf8.decode(data, allowMalformed: true),
    };
  }
}

// The status codes of a redirect, for every method.
const _redirects = {301, 302, 303, 307, 308};

const _source = '''
(raw) => {
  const toBody = (body) => {
    if (body === undefined || body === null) return null;
    if (typeof body === 'string') return body;
    if (body instanceof ArrayBuffer) return new Uint8Array(body);
    if (ArrayBuffer.isView(body)) {
      return new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
    }
    return String(body);
  };
  const fetch = async (input, init = {}) => {
    const headers = {};
    for (const [name, value] of Object.entries(init.headers ?? {})) {
      headers[name] = String(value);
    }
    const response = await raw(String(input), {
      method: String(init.method ?? 'GET').toUpperCase(),
      headers,
      body: toBody(init.body),
    });
    const body = response.body;
    return {
      status: response.status,
      statusText: response.statusText,
      ok: response.status >= 200 && response.status < 300,
      url: response.url,
      redirected: response.redirected,
      headers: {
        get: (name) => response.headers[String(name).toLowerCase()] ?? null,
        has: (name) => String(name).toLowerCase() in response.headers,
        entries: () => Object.entries(response.headers),
      },
      text: async () => response.text,
      json: async () => JSON.parse(response.text),
      arrayBuffer: async () =>
        body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength),
      bytes: async () => body,
    };
  };
  Object.defineProperty(globalThis, 'fetch', {
    value: fetch,
    writable: true,
    configurable: true,
  });
}
''';
