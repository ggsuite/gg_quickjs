# Changelog

## Unreleased

### Added

- Initial boilerplate
- Add QuickJS-ng 0.17.0, a hook helper and a Dart binding

- src/quickjs-ng: the library subset of QuickJS-ng 0.17.0, unchanged, with its LICENSE and a NOTICE
- tool/update-quickjs-ng.js: fetches a tag of QuickJS-ng and copies the subset
- package:gg_quickjs/hook.dart: QuickjsNgBuild builds QuickJS-ng as a static library for the build hooks of other packages
- hook/build.dart and hook/link.dart: the native library gg_quickjs with the C bridge src/gg_quickjs.c, dropped from apps that never use it
- JsRuntime: evaluate, modules, bytecode, handles, host functions, promises and futures, limits, interrupt
- JsRuntime.spawn: the same API as futures on a worker isolate
- Sandbox: console, timers, fetch and fs exist only when JsRuntimeOptions grants them
- README in English and German, an example and tests at full coverage
- README: why the types are named Js… without the Gg prefix

Co-Authored-By: Claude Opus 5.5 [noreply@anthropic.com](mailto:noreply@anthropic.com)
