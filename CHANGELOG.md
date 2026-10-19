# Changelog

## 0.1.0 - 2026-10-19

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

- Add review fixes: conversion limits, fetch, handles

- src/gg_quickjs.c: a conversion to Dart keeps to the timeout, an interrupt and four times the memory limit, e.g. for a sparse array

- src/gg_quickjs.c: a call holds its function, this and the value it converts; Map entries of a replaced iterator fail cleanly; a huge timeout or memory limit no longer overflows

- JsRuntime: frees the handles disposed during a call once it returns; a runtime that nobody disposes no longer keeps its isolate alive; a revoked host function releases its argument handles

- fetch: drops Host and the other headers that HTTP controls and refuses a response beyond memoryLimit

- setTimeout and setInterval: wait at most 2^31 - 1 ms instead of failing for Infinity

- fs.list: lists a folder asynchronously

- tool/update-quickjs-ng.js: accepts only a plain tag name for its shell command

- doc/blog/2026/2026-10-19-quickjs-ng-for-build-hooks-and-dart.md: the blog post of gg_quickjs 0.1.0, in English and in German under doc/de/blog

- index.jsonc: summary, domain and interfaces of the repo

- README in English and German, API docs and tests
