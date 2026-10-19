// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:typed_data';

import 'js_exception.dart';
import 'js_runtime.dart';
import 'js_undefined.dart';

// #############################################################################
/// The kinds of a handle in the value encoding, as `src/gg_quickjs.c`
/// writes them.
enum JsHandleKind {
  /// A primitive that stays in JavaScript, e.g. a symbol.
  other,

  /// An object.
  object,

  /// A function.
  function,

  /// A promise.
  promise,

  /// An `ArrayBuffer`.
  arrayBuffer,
}

// #############################################################################
/// What the codec needs from a runtime for the values that do not cross as
/// copies: handles, Dart functions and futures.
abstract interface class JsCodecHost {
  /// The address of [handle]; throws when it belongs to another runtime or
  /// is disposed.
  int addressOf(JsValue handle);

  /// Registers [function] as a host function and returns its id.
  int registerFunction(Function function);

  /// The address of a new promise that settles with [future].
  int promiseOf(Future<Object?> future);

  /// The Dart value of the handle [address] of [kind]: a handle, or a
  /// future for a promise.
  Object? valueOf(JsHandleKind kind, int address);
}

// #############################################################################
/// Encodes Dart values for `src/gg_quickjs.c` and decodes its values, see
/// the `GG_QJS_TAG_*` constants of `src/gg_quickjs.h`.
///
/// Without a [host] the codec copies data only, as between the isolates of a
/// [JsIsolateRuntime]: Dart functions, futures and handles are refused, or
/// become null with [dropUncopyable], and handles from JavaScript decode to
/// null.
final class JsValueCodec {
  /// Creates a codec for [host].
  ///
  /// - [host] the runtime of handles, functions and futures
  /// - [dropUncopyable] whether a codec without [host] encodes a value that
  ///   cannot be copied as null instead of refusing it
  const JsValueCodec({this.host, this.dropUncopyable = false});

  /// Creates an example codec that copies data only.
  factory JsValueCodec.example() => const JsValueCodec();

  // ...........................................................................
  /// Encodes [value]; throws an [ArgumentError] for a value that JavaScript
  /// cannot take.
  Uint8List encode(Object? value) {
    final writer = _Writer();
    _encode(writer, value, 0);
    return writer.takeBytes();
  }

  /// Decodes [bytes].
  Object? decode(Uint8List bytes) => _Reader(bytes, host).read(0);

  /// Encodes the host function [id] as a JavaScript function named [name].
  static Uint8List encodeHostFunction({required int id, required String name}) {
    final writer = _Writer();
    _writeHostFunction(writer, id, name);
    return writer.takeBytes();
  }

  // ...........................................................................
  /// The runtime for handles, functions and futures; null to copy data only.
  final JsCodecHost? host;

  /// Whether a codec without [host] encodes a value that cannot be copied
  /// as null instead of refusing it.
  final bool dropUncopyable;

  // ...........................................................................
  /// The deepest nesting that the codec follows, as the bridge does.
  static const int maxDepth = 256;

  // ...........................................................................
  void _encode(_Writer out, Object? value, int depth) {
    if (depth > maxDepth) {
      throw ArgumentError('A value nested deeper than $maxDepth levels');
    }
    switch (value) {
      case null:
        out.u8(_tagNull);
      case JsUndefined():
        out.u8(_tagUndefined);
      case bool():
        out.u8(value ? _tagTrue : _tagFalse);
      case int():
        _encodeInt(out, value);
      case double():
        out
          ..u8(_tagFloat64)
          ..f64(value);
      case String():
        out
          ..u8(_tagString)
          ..text(value);
      case BigInt():
        out
          ..u8(_tagBigInt)
          ..text(value.toString());
      case DateTime():
        out
          ..u8(_tagDate)
          ..f64(value.microsecondsSinceEpoch / 1000);
      case ByteBuffer():
        _encodeBytes(out, _bytesArrayBuffer, value.asUint8List());
      case TypedData():
        _encodeTypedData(out, value);
      case JsException():
        out
          ..u8(_tagError)
          ..text(value.name)
          ..text(value.message)
          ..text(value.stack);
      case List<Object?>():
        out
          ..u8(_tagArray)
          ..u32(value.length);
        for (final item in value) {
          _encode(out, item, depth + 1);
        }
      case Set<Object?>():
        out
          ..u8(_tagSet)
          ..u32(value.length);
        for (final item in value) {
          _encode(out, item, depth + 1);
        }
      case Map<Object?, Object?>():
        _encodeMap(out, value, depth);
      case Future<Object?>() when host != null:
        _encodeHandle(out, host!.promiseOf(value));
      case Function() when host != null:
        _encodeFunction(out, value);
      case JsValue() when host != null:
        _encodeHandle(out, host!.addressOf(value));
      case Future<Object?>() || Function() || JsValue() when dropUncopyable:
        out.u8(_tagNull);
      default:
        throw ArgumentError.value(
          value,
          'value',
          host == null
              ? 'A ${value.runtimeType} cannot be copied to another isolate'
              : 'A ${value.runtimeType} cannot cross to JavaScript',
        );
    }
  }

  void _encodeInt(_Writer out, int value) {
    if (value >= -0x80000000 && value <= 0x7fffffff) {
      out
        ..u8(_tagInt32)
        ..i32(value);
    } else if (value.abs() <= _maxSafeInteger) {
      out
        ..u8(_tagFloat64)
        ..f64(value.toDouble());
    } else {
      out
        ..u8(_tagBigInt)
        ..text(value.toString());
    }
  }

  void _encodeMap(_Writer out, Map<Object?, Object?> value, int depth) {
    final plain = value.keys.every((key) => key is String);
    out
      ..u8(plain ? _tagObject : _tagMap)
      ..u32(value.length);
    for (final MapEntry(:key, value: item) in value.entries) {
      if (plain) {
        out.text(key! as String);
      } else {
        _encode(out, key, depth + 1);
      }
      _encode(out, item, depth + 1);
    }
  }

  void _encodeTypedData(_Writer out, TypedData value) {
    final kind = switch (value) {
      Uint8ClampedList() => _bytesUint8Clamped,
      Uint8List() => _bytesUint8,
      Int8List() => _bytesInt8,
      Int16List() => _bytesInt16,
      Uint16List() => _bytesUint16,
      Int32List() => _bytesInt32,
      Uint32List() => _bytesUint32,
      Float32List() => _bytesFloat32,
      Float64List() => _bytesFloat64,
      Int64List() => _bytesBigInt64,
      Uint64List() => _bytesBigUint64,
      _ => _bytesUint8,
    };
    _encodeBytes(
      out,
      kind,
      value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes),
    );
  }

  void _encodeBytes(_Writer out, int kind, Uint8List bytes) {
    out
      ..u8(_tagBytes)
      ..u8(kind)
      ..u32(bytes.length)
      ..raw(bytes);
  }

  void _encodeHandle(_Writer out, int address) {
    out
      ..u8(_tagHandle)
      ..u8(0)
      ..u64(address);
  }

  void _encodeFunction(_Writer out, Function value) =>
      _writeHostFunction(out, host!.registerFunction(value), '');

  static void _writeHostFunction(_Writer out, int id, String name) {
    out
      ..u8(_tagHostFunction)
      ..u64(id)
      ..text(name)
      ..u32(0);
  }
}

// .............................................................................
// The tags of src/gg_quickjs.h

const int _tagUndefined = 0;
const int _tagNull = 1;
const int _tagFalse = 2;
const int _tagTrue = 3;
const int _tagInt32 = 4;
const int _tagFloat64 = 5;
const int _tagString = 6;
const int _tagBigInt = 7;
const int _tagArray = 8;
const int _tagObject = 9;
const int _tagDate = 10;
const int _tagBytes = 11;
const int _tagError = 12;
const int _tagHandle = 13;
const int _tagMap = 14;
const int _tagSet = 15;
const int _tagHostFunction = 16;

const int _bytesArrayBuffer = 0;
const int _bytesUint8 = 1;
const int _bytesInt8 = 2;
const int _bytesUint8Clamped = 3;
const int _bytesInt16 = 4;
const int _bytesUint16 = 5;
const int _bytesInt32 = 6;
const int _bytesUint32 = 7;
const int _bytesFloat32 = 8;
const int _bytesFloat64 = 9;
const int _bytesBigInt64 = 10;
const int _bytesBigUint64 = 11;

const int _maxSafeInteger = 9007199254740991;

// #############################################################################
/// Writes an encoded value.
class _Writer {
  final _builder = BytesBuilder(copy: false);
  final _scratch = ByteData(8);

  void u8(int value) => _builder.addByte(value);

  void u32(int value) {
    _scratch.setUint32(0, value, Endian.host);
    _builder.add(_scratch.buffer.asUint8List(0, 4).sublist(0));
  }

  void i32(int value) {
    _scratch.setInt32(0, value, Endian.host);
    _builder.add(_scratch.buffer.asUint8List(0, 4).sublist(0));
  }

  void u64(int value) {
    _scratch.setUint64(0, value, Endian.host);
    _builder.add(_scratch.buffer.asUint8List(0, 8).sublist(0));
  }

  void f64(double value) {
    _scratch.setFloat64(0, value, Endian.host);
    _builder.add(_scratch.buffer.asUint8List(0, 8).sublist(0));
  }

  void raw(Uint8List bytes) => _builder.add(Uint8List.fromList(bytes));

  void text(String value) {
    final bytes = utf8.encode(value);
    u32(bytes.length);
    _builder.add(bytes);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

// #############################################################################
/// Reads an encoded value.
class _Reader {
  _Reader(this._bytes, this._host) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  final JsCodecHost? _host;
  int _position = 0;

  Object? read(int depth) {
    final tag = _u8();
    return switch (tag) {
      _tagUndefined || _tagNull => null,
      _tagFalse => false,
      _tagTrue => true,
      _tagInt32 => _i32(),
      _tagFloat64 => _number(_f64()),
      _tagString => _text(),
      _tagBigInt => BigInt.parse(_text()),
      _tagArray => _list(depth),
      _tagObject => _object(depth),
      _tagDate => _date(_f64()),
      _tagBytes => _typedData(),
      _tagError => JsException.from(
        name: _text(),
        message: _text(),
        stack: _text(),
      ),
      _tagHandle => _handle(),
      _tagMap => _map(depth),
      _tagSet => _set(depth),
      _ => throw FormatException('Unknown tag $tag of an encoded value'),
    };
  }

  int _u8() => _bytes[_position++];

  int _u32() {
    final value = _data.getUint32(_position, Endian.host);
    _position += 4;
    return value;
  }

  int _i32() {
    final value = _data.getInt32(_position, Endian.host);
    _position += 4;
    return value;
  }

  int _u64() {
    final value = _data.getUint64(_position, Endian.host);
    _position += 8;
    return value;
  }

  double _f64() {
    final value = _data.getFloat64(_position, Endian.host);
    _position += 8;
    return value;
  }

  Uint8List _raw(int length) {
    final bytes = _bytes.sublist(_position, _position + length);
    _position += length;
    return bytes;
  }

  String _text() => utf8.decode(_raw(_u32()), allowMalformed: true);

  // An integral number in the safe range becomes an int, as JavaScript does
  // not tell them apart; -0 stays a double.
  Object _number(double value) {
    final integral =
        value.isFinite &&
        value == value.truncateToDouble() &&
        value.abs() <= _maxSafeInteger &&
        !(value == 0 && value.isNegative);
    return integral ? value.toInt() : value;
  }

  // An invalid date becomes null.
  DateTime? _date(double milliseconds) => milliseconds.isFinite
      ? DateTime.fromMicrosecondsSinceEpoch(
          (milliseconds * 1000).round(),
          isUtc: true,
        )
      : null;

  List<Object?> _list(int depth) {
    final length = _u32();
    return [for (var i = 0; i < length; i++) read(depth + 1)];
  }

  Set<Object?> _set(int depth) {
    final length = _u32();
    return {for (var i = 0; i < length; i++) read(depth + 1)};
  }

  Map<String, Object?> _object(int depth) {
    final length = _u32();
    final result = <String, Object?>{};
    for (var i = 0; i < length; i++) {
      final key = _text();
      result[key] = read(depth + 1);
    }
    return result;
  }

  Map<Object?, Object?> _map(int depth) {
    final length = _u32();
    final result = <Object?, Object?>{};
    for (var i = 0; i < length; i++) {
      final key = read(depth + 1);
      result[key] = read(depth + 1);
    }
    return result;
  }

  Object _typedData() {
    final kind = _u8();
    final bytes = _raw(_u32());
    final buffer = bytes.buffer;
    return switch (kind) {
      _bytesArrayBuffer => buffer,
      _bytesInt8 => buffer.asInt8List(),
      _bytesUint8Clamped => buffer.asUint8ClampedList(),
      _bytesInt16 => buffer.asInt16List(),
      _bytesUint16 => buffer.asUint16List(),
      _bytesInt32 => buffer.asInt32List(),
      _bytesUint32 => buffer.asUint32List(),
      _bytesFloat32 => buffer.asFloat32List(),
      _bytesFloat64 => buffer.asFloat64List(),
      _bytesBigInt64 => buffer.asInt64List(),
      _bytesBigUint64 => buffer.asUint64List(),
      _ => bytes,
    };
  }

  Object? _handle() {
    final kind = JsHandleKind.values[_u8()];
    final address = _u64();
    return _host?.valueOf(kind, address);
  }
}
