// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// An error that JavaScript threw, or that stopped JavaScript, classified by
/// its kind.
///
/// A [JsRuntime] throws it; a host function throws it to raise the error of
/// the same name in JavaScript.
///
/// ```dart
/// try {
///   runtime.evaluate('null.x');
/// } on JsTypeError catch (error) {
///   print('${error.message} at ${error.line}:${error.column}');
/// }
/// ```
sealed class JsException implements Exception {
  /// Creates an exception; [line] and [column] default to the first
  /// position that [stack] names.
  ///
  /// - [name] the name of the JavaScript error, e.g. `TypeError`
  /// - [message] the message of the error
  /// - [stack] the JavaScript stack trace, empty when there is none
  /// - [line] the line of the error, 1-based
  /// - [column] the column of the error, 1-based
  JsException({
    required this.name,
    required this.message,
    this.stack = '',
    int? line,
    int? column,
  }) : line = line ?? _position(stack)?.$1,
       column = column ?? _position(stack)?.$2;

  /// Creates the exception of the kind that [name] and [message] tell, e.g.
  /// a [JsTypeError] for `TypeError`.
  factory JsException.from({
    required String name,
    required String message,
    String stack = '',
  }) => switch (name) {
    'SyntaxError' => JsSyntaxError(message: message, stack: stack),
    'TypeError' => JsTypeError(message: message, stack: stack),
    'ReferenceError' => JsReferenceError(message: message, stack: stack),
    'RangeError' when message == JsStackOverflowError.defaultMessage =>
      JsStackOverflowError(stack: stack),
    'RangeError' => JsRangeError(message: message, stack: stack),
    'InternalError' when message == JsOutOfMemoryError.defaultMessage =>
      JsOutOfMemoryError(stack: stack),
    _ => JsError(name: name, message: message, stack: stack),
  };

  /// The exception for a value that JavaScript threw or rejected with: the
  /// [JsException] that an error converts to, a [JsError] with
  /// [JsError.thrownValue] for any other value.
  factory JsException.fromThrown(Object? value) => value is JsException
      ? value
      : JsError(message: '$value', thrownValue: value);

  /// The exception that JavaScript receives for an [error] of Dart code: a
  /// [JsException] as it is, an [ArgumentError] as a [JsTypeError], any
  /// other error as a [JsError] with its text.
  factory JsException.fromDartError(Object error) => switch (error) {
    JsException() => error,
    ArgumentError(:final message) => JsTypeError(message: '$message'),
    _ => JsError(message: '$error'),
  };

  // ...........................................................................
  @override
  String toString() =>
      stack.isEmpty ? '$name: $message' : '$name: $message\n$stack';

  // ...........................................................................
  /// The name of the JavaScript error, e.g. `TypeError`.
  final String name;

  /// The message of the error.
  final String message;

  /// The JavaScript stack trace, empty when there is none.
  final String stack;

  /// The line of the error, 1-based; null when the stack names none.
  final int? line;

  /// The column of the error, 1-based; null when the stack names none.
  final int? column;

  // ...........................................................................
  static final _frame = RegExp(r'^\s*at (?:.*\()?(.+):(\d+):(\d+)\)?\s*$');

  // The line and column of the first frame of [stack] that names them.
  static (int, int)? _position(String stack) {
    for (final line in stack.split('\n')) {
      final match = _frame.firstMatch(line);
      if (match != null) {
        return (int.parse(match.group(2)!), int.parse(match.group(3)!));
      }
    }
    return null;
  }
}

// #############################################################################
/// A `SyntaxError`: the source does not parse.
final class JsSyntaxError extends JsException {
  /// Creates a syntax error with [message].
  JsSyntaxError({required super.message, super.stack, super.line, super.column})
    : super(name: 'SyntaxError');

  /// Creates an example syntax error for tests and docs.
  factory JsSyntaxError.example({String? message}) => JsSyntaxError(
    message: message ?? 'unexpected token in expression',
    stack: '    at main.js:1:5\n',
  );
}

// #############################################################################
/// A `TypeError`, e.g. a property read of `null`.
final class JsTypeError extends JsException {
  /// Creates a type error with [message].
  JsTypeError({required super.message, super.stack, super.line, super.column})
    : super(name: 'TypeError');

  /// Creates an example type error for tests and docs.
  factory JsTypeError.example({String? message}) => JsTypeError(
    message: message ?? "cannot read property 'x' of null",
    stack: '    at <eval> (main.js:2:7)\n',
  );
}

// #############################################################################
/// A `ReferenceError`, e.g. an undeclared variable.
final class JsReferenceError extends JsException {
  /// Creates a reference error with [message].
  JsReferenceError({
    required super.message,
    super.stack,
    super.line,
    super.column,
  }) : super(name: 'ReferenceError');

  /// Creates an example reference error for tests and docs.
  factory JsReferenceError.example({String? message}) => JsReferenceError(
    message: message ?? 'answer is not defined',
    stack: '    at <eval> (main.js:1:1)\n',
  );
}

// #############################################################################
/// A `RangeError` other than a stack overflow, e.g. an invalid array
/// length.
final class JsRangeError extends JsException {
  /// Creates a range error with [message].
  JsRangeError({required super.message, super.stack, super.line, super.column})
    : super(name: 'RangeError');

  /// Creates an example range error for tests and docs.
  factory JsRangeError.example({String? message}) => JsRangeError(
    message: message ?? 'invalid array length',
    stack: '    at <eval> (main.js:1:11)\n',
  );
}

// #############################################################################
/// JavaScript stopped by [JsRuntime.interrupt], by the time budget of
/// [JsRuntimeOptions.timeout] or by the disposal of its runtime.
final class JsInterruptedError extends JsException {
  /// Creates an interruption.
  ///
  /// - [timedOut] whether the time budget ran out
  JsInterruptedError({
    super.message = 'interrupted',
    super.stack,
    this.timedOut = false,
  }) : super(name: 'InternalError');

  /// Creates an example interruption for tests and docs.
  factory JsInterruptedError.example({bool? timedOut}) =>
      JsInterruptedError(timedOut: timedOut ?? true);

  /// Whether the time budget of the runtime ran out.
  final bool timedOut;
}

// #############################################################################
/// JavaScript ran out of the memory of [JsRuntimeOptions.memoryLimit].
final class JsOutOfMemoryError extends JsException {
  /// Creates an out-of-memory error.
  JsOutOfMemoryError({super.message = defaultMessage, super.stack})
    : super(name: 'InternalError');

  /// Creates an example out-of-memory error for tests and docs.
  factory JsOutOfMemoryError.example({String? message}) =>
      JsOutOfMemoryError(message: message ?? defaultMessage);

  /// The message of QuickJS-ng for an exhausted memory limit.
  static const String defaultMessage = 'out of memory';
}

// #############################################################################
/// JavaScript ran out of the stack of [JsRuntimeOptions.maxStackSize], e.g.
/// in an endless recursion.
final class JsStackOverflowError extends JsException {
  /// Creates a stack overflow.
  JsStackOverflowError({super.message = defaultMessage, super.stack})
    : super(name: 'RangeError');

  /// Creates an example stack overflow for tests and docs.
  factory JsStackOverflowError.example({String? stack}) =>
      JsStackOverflowError(stack: stack ?? '    at f (main.js:1:16)\n');

  /// The message of QuickJS-ng for an exhausted stack.
  static const String defaultMessage = 'Maximum call stack size exceeded';
}

// #############################################################################
/// Any other error: an `Error`, `EvalError`, `URIError`, a subclass of
/// JavaScript's own, or a thrown value that is no error at all.
final class JsError extends JsException {
  /// Creates an error.
  ///
  /// - [name] the name of the error, `Error` by default
  /// - [thrownValue] the value JavaScript threw when it was no error, e.g.
  ///   `42` for `throw 42`
  JsError({
    super.name = 'Error',
    required super.message,
    super.stack,
    super.line,
    super.column,
    this.thrownValue,
  });

  /// Creates an example error for tests and docs.
  factory JsError.example({String? name, String? message}) => JsError(
    name: name ?? 'Error',
    message: message ?? 'the answer is not 42',
    stack: '    at check (main.js:3:11)\n',
  );

  /// The value JavaScript threw when it was no error; null otherwise.
  final Object? thrownValue;
}
