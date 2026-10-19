<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# gg_quickjs

[English](README.md) | Deutsch

[![CI](https://github.com/ggsuite/gg_quickjs/actions/workflows/quick_check.yaml/badge.svg)](https://github.com/ggsuite/gg_quickjs/actions/workflows/quick_check.yaml)
[![pub package](https://img.shields.io/pub/v/gg_quickjs.svg)](https://pub.dev/packages/gg_quickjs)

QuickJS-ng für Dart: seine C-Quellen für die Build-Hooks nativer Pakete und
ein Dart-Binding mit typisierten Werten, einem Hintergrund-Isolate und einer
Sandbox.

Es enthält QuickJS-ng 0.17.0 und läuft auf iOS, Android, macOS, Linux und
Windows, nicht im Web. Ein Build-Hook übersetzt es aus den Quellen auf dem
Rechner, der die App baut: kein Download, keine vorgefertigte Binärdatei.

## Motivation

- Mehrere Pakete einer App brauchen QuickJS-ng womöglich in ihrem eigenen
  nativen Code. `gg_quickjs` hält die Quellen einmal und gibt den Build-Hooks
  dieser Pakete einen Aufruf, der sie in deren eigene Bibliothek übersetzt,
  jede Kopie mit verborgenen Symbolen, damit sich die Kopien nie in die
  Quere kommen.
- Die QuickJS-Pakete auf pub.dev binden ältere Engines, laden vorgefertigte
  Binärdateien, liefern Ergebnisse als Strings oder fragen Promises mit
  Timern ab, und keines bietet seine C-Quellen anderen Build-Hooks an.
- Eine App, die Skripte ausführt, will Grenzen und eine Sandbox, auf die sie
  sich von Haus aus verlassen kann: keine Dateien, kein Netz, keine Timer und
  keine Konsole, bis Dart sie gewährt.

## Installation

```bash
dart pub add gg_quickjs
```

Der Build-Hook braucht einen C-Compiler für das Ziel: Xcode für iOS und
macOS, das Android-NDK, das Flutter nutzt, Clang oder GCC unter Linux, Visual
Studio unter Windows.

## Verwendung

```dart
import 'package:gg_quickjs/gg_quickjs.dart';

Future<void> main() async {
  // A runtime with limits that grants console output and nothing else
  final runtime = JsRuntime(
    options: JsRuntimeOptions(
      memoryLimit: 32 * 1024 * 1024,
      timeout: const Duration(seconds: 1),
      onConsole: (level, message) => print('[${level.name}] $message'),
    ),
  );

  // Values cross as Dart values
  print(runtime.evaluate('({answer: 6 * 7, primes: [2, 3, 5]})'));

  // A Dart function for JavaScript; its Future becomes a promise
  runtime.registerFunction('greet', (args) async => 'Hello ${args[0]}!');
  print(await (runtime.evaluate('greet("Dart")')! as Future<Object?>));

  // Errors of JavaScript as typed exceptions
  try {
    runtime.evaluate('null.answer', sourceUrl: 'main.js');
  } on JsTypeError catch (error) {
    print('${error.name} at ${error.line}:${error.column}: ${error.message}');
  }

  // The sandbox: no network and no files unless Dart grants them
  runtime.evaluate('console.log(typeof fetch, typeof fs)');
  runtime.dispose();

  // The same API as futures, with the runtime on a background isolate
  final background = await JsRuntime.spawn();
  print(await background.evaluate('[1, 2, 3].map((x) => x * x)'));
  await background.dispose();
}
```

Es gibt aus:

```text
{answer: 42, primes: [2, 3, 5]}
Hello Dart!
TypeError at 1:1: cannot read property 'answer' of null
[log] undefined undefined
[1, 4, 9]
```

### Werte austauschen

`evaluate`, `call`, `getGlobal` und die Argumente von Host-Funktionen wandeln
Werte in beide Richtungen um:

| JavaScript | Dart |
| --- | --- |
| `undefined`, `null` | `null`; `jsUndefined` übergibt `undefined` |
| Boolean, String | `bool`, `String` |
| Zahl | `int`, wenn ganzzahlig und sicher, sonst `double` |
| `bigint` | `BigInt`; ein `int` jenseits von 2^53 wird zu einem |
| Array, Objekt | `List`, `Map` mit `String`-Schlüsseln |
| `Map`, `Set` | `Map`, `Set` |
| `Date` | `DateTime` in UTC |
| `ArrayBuffer`, typisierte Arrays | `ByteBuffer`, `Uint8List` und die anderen typisierten Listen |
| `Error` | die `JsException` seiner Art |
| Funktion | `JsFunction`; eine Dart-Funktion wird zur JavaScript-Funktion |
| Promise | `Future`; ein `Future` wird zum Promise |

`evaluateHandle` hält einen Wert als `JsValue` in JavaScript: `JsObject`,
`JsFunction`, `JsPromise`, `JsArrayBuffer` oder `JsPrimitive`. Ein Handle lebt
bis `dispose()`, bis Dart es einsammelt oder bis seine Laufzeit freigegeben
ist; `withJsValues` gibt einen Bereich von ihnen frei:

```dart
final sum = withJsValues((scope) {
  final add = scope.own(runtime.evaluateHandle('(a, b) => a + b'));
  return (add as JsFunction)([20, 22]);
});
```

### Module und Bytecode ausführen

```dart
runtime.registerModules({'math': 'export const twice = (x) => 2 * x;'});
final exports = await runtime.evaluateModule(
  "import { twice } from 'math'; export const answer = twice(21);",
);
final bytecode = runtime.compile('6 * 7');
print([exports['answer'], runtime.evaluateBytecode(bytecode)]); // [42, 42]
```

`import` löst zuerst registrierte Module auf, dann
`JsRuntimeOptions.moduleLoader`, dann, mit Dateisystem-Freigabe, die Dateien
unter deren Wurzeln. Führen Sie nur Bytecode aus, den dieses Paket übersetzt
hat.

### Begrenzen und unterbrechen

`JsRuntimeOptions` nimmt `memoryLimit`, `maxStackSize`, `gcThreshold` und
`timeout`, die Zeit, die ein Aufruf in JavaScript samt seinen ausstehenden
Jobs dauern darf. `interrupt()` stoppt das JavaScript, das gerade läuft.
Fehler kommen als versiegelte `JsException` an: `JsSyntaxError`,
`JsTypeError`, `JsReferenceError`, `JsRangeError`, `JsInterruptedError`,
`JsOutOfMemoryError`, `JsStackOverflowError` und `JsError` für den Rest, jede
mit `name`, `message`, `stack`, `line` und `column`.

### Ein Hintergrund-Isolate nutzen

`JsRuntime.spawn()` liefert eine `JsIsolateRuntime`: Ein Worker-Isolate
besitzt die Laufzeit, die Methoden liefern Futures, und Werte gehen als
Kopien hinüber. Registrierte Funktionen laufen im aufrufenden Isolate, daher
erhält JavaScript ein Promise ihres Ergebnisses. `interrupt()` setzt ein Flag
der nativen Laufzeit und wirkt, während der Worker beschäftigt ist;
`dispose()` unterbricht die laufenden Aufrufe, `dispose(graceful: true)` lässt
sie enden.

### Fähigkeiten gewähren

Die Sandbox ist eine Fähigkeiten-Richtlinie: Ohne Freigabe gibt es die
Objekte in JavaScript nicht, und die Engine ist ohne `quickjs-libc` gebaut,
es gibt also kein Modul `std` oder `os`.

```dart
final runtime = JsRuntime(
  options: JsRuntimeOptions(
    onConsole: (level, message) => print(message),
    timers: true,
    network: JsNetworkAccess(
      allowedHosts: {'api.example.com'},
      allowUrl: (url) => url.path.startsWith('/v1/'),
    ),
    fileSystem: JsFileSystemAccess(
      readRoots: ['/data/scripts'],
      writeRoots: ['/data/output'],
    ),
  ),
);
```

- `onConsole` fügt `console` hinzu; `timers` fügt `setTimeout`,
  `setInterval`, `clearTimeout` und `clearInterval` auf Dart-Timern hinzu.
- `network` fügt `fetch` hinzu, das nur die erlaubten Hosts erreicht und
  jede Weiterleitung erneut prüft.
- `fileSystem` fügt ein globales `fs` mit `readText`, `readBytes`,
  `writeText`, `writeBytes`, `exists`, `list` und `remove` hinzu und lässt
  `import` Dateien laden. Pfade müssen absolut sein; `..` und symbolische
  Links werden vor der Prüfung aufgelöst, sodass keines eine Wurzel verlässt.

### QuickJS-ng in die eigene native Bibliothek bauen

`package:gg_quickjs/hook.dart` ist für den Build-Hook eines Pakets mit
eigenem nativem Code. `QuickjsNgBuild.run` übersetzt QuickJS-ng als statische
Bibliothek in die Ausgabe des Hooks, und die Bibliothek des Pakets bindet sie
ein:

```dart
// hook/build.dart
import 'package:code_assets/code_assets.dart';
import 'package:gg_quickjs/hook.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    const quickjs = QuickjsNgBuild(libraryName: 'my_engine_quickjs_ng');
    await quickjs.run(input: input, output: output);
    await CBuilder.library(
      name: input.packageName,
      assetName: 'src/my_engine_bindings.dart',
      sources: ['src/my_engine.c'],
      includes: [await QuickjsNgBuild.includeDirectory()],
      flags: QuickjsNgBuild.libraryFlags(os),
      libraries: [quickjs.libraryName, ...QuickjsNgBuild.systemLibraries(os)],
    ).run(input: input, output: output);
  });
}
```

Der Helfer nennt auch die Quellen, die Defines und die Compiler-Flags je
Plattform für einen eigenen Build. Er baut nur den Kern, ohne
`quickjs-libc`. Das Paket hängt von `gg_quickjs`, `hooks`, `code_assets` und
`native_toolchain_c` ab; liefern Sie die `NOTICE` von QuickJS-ng mit der App
aus.

## Grenzen

- Die Sandbox ist eine Fähigkeiten-Richtlinie, kein Schutz vor feindseligem
  Code. QuickJS-ng ist ein in C geschriebener Interpreter; ein Fehler darin
  kann den Speicher der App beschädigen. Führen Sie Code, dem Sie nicht
  vertrauen, in einem eigenen Prozess aus.
- QuickJS-ng 0.17.0 erholt sich nicht immer, wenn ihm beim Übersetzen der
  Speicher ausgeht: Der Code, den Dart übergibt, wird ohne Speichergrenze
  übersetzt, aber `eval` oder `new Function` in einem Skript, das seinen
  Speicher aufgebraucht hat, kann den Prozess abstürzen lassen.
- `maxStackSize` zählt ab dem Aufruf in JavaScript; die Vorgabe von 256 KiB
  erlaubt etwa 250 verschachtelte Aufrufe. Der native Stack eines
  Dart-Isolates fasst auf 64-Bit-Plattformen etwa 1 MiB, daher kann eine
  Grenze über 512 KiB abstürzen, statt einen `JsStackOverflowError` zu
  werfen.
- `timeout` und `interrupt()` stoppen JavaScript, keine Dart-Host-Funktion
  und kein laufendes `fetch`.
- Apples App-Review-Richtlinien beschränken Code, den eine App lädt und
  ausführt (Richtlinie 4.7, siehe auch 2.5.2). Liefern Sie die Skripte einer
  iOS-App mit ihr aus, oder prüfen Sie die Richtlinien, bevor Sie Skripte von
  anderswo ausführen.
- Keine Unterstützung für das Web, kein `Atomics.wait`, kein Modul `std` oder
  `os`.

## Dokumentation

- Die API-Referenz auf [pub.dev](https://pub.dev/documentation/gg_quickjs/latest/)
- Die C-Brücke zwischen Dart und QuickJS-ng: [src/gg_quickjs.h](src/gg_quickjs.h)
- QuickJS-ng: [github.com/quickjs-ng/quickjs](https://github.com/quickjs-ng/quickjs)

## Funktionsweise

- `hook/build.dart` übersetzt QuickJS-ng mit `QuickjsNgBuild` und bindet es
  mit der Brücke `src/gg_quickjs.c` in die dynamische Bibliothek
  `gg_quickjs` ein, ein Native Asset. `hook/link.dart` entfernt sie aus dem
  Release-Build einer App, die nie eine `JsRuntime` erzeugt.
- Werte gehen in einer kompakten binären Kodierung über die Brücke; Objekte,
  die in JavaScript bleiben, gehen als Handles hinüber. Nach jedem Aufruf in
  JavaScript führt die Brücke die ausstehenden Jobs von Promises aus und
  meldet unbehandelte Ablehnungen.
- Die Brücke aktualisiert bei jedem Aufruf das obere Ende des Stacks, damit
  eine Laufzeit zwischen den Threads eines Isolates wechseln darf, setzt die
  Speichergrenze in ihrem Allokator durch und stoppt einen Aufruf über den
  Interrupt-Handler von QuickJS-ng.

## Status

Vor 1.0 — die API kann sich zwischen Minor-Versionen ändern. Die Versionen
von `gg_quickjs` sind eigene; `quickjsNgVersion` nennt die Version von
QuickJS-ng, die es enthält.
Anders als die übrigen ggsuite-Pakete heißen seine Typen `Js…`
(`JsRuntime`, `JsValue`, `JsException`), ohne das Präfix `Gg`, nach dem
Vokabular der QuickJS-Pakete auf pub.dev.

## Mitwirken

- Folgen Sie dem [Entwicklungsleitfaden](doc/guides/develop-guide.md), dem
  [Code-Leitfaden](doc/guides/code-guide.md) und dem
  [Test-Leitfaden](doc/guides/test-guide.md).
- Aktualisieren Sie QuickJS-ng mit `node tool/update-quickjs-ng.js <tag>`,
  z. B. `v0.17.0`; das Skript kopiert die Teilmenge und setzt die
  Versionskonstante.

## Lizenz

MIT — siehe [LICENSE](LICENSE). Auch QuickJS-ng steht unter MIT, siehe
[NOTICE](NOTICE) und [src/quickjs-ng/LICENSE](src/quickjs-ng/LICENSE).
