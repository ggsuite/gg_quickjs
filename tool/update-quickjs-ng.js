#!/usr/bin/env node

/**
 * @license
 * Copyright (c) ggsuite
 *
 * Use of this source code is governed by terms that can be
 * found in the LICENSE file in the root of this package.
 */

// Fetches a tag of QuickJS-ng and copies the library subset that
// gg_quickjs compiles - the core engine without quickjs-libc, qjs or qjsc -
// with its LICENSE into src/quickjs-ng. The files stay unchanged. Updates
// the version constant in lib/src/quickjs_ng_version.dart.
//
// Usage: node tool/update-quickjs-ng.js <tag>, e.g. v0.17.0

import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

import { gray, green, red, yellow } from '../scripts/functions/colors.js';
import { runCommand } from '../scripts/functions/run-command.js';

// .............................................................................
// The subset

const repository = 'https://github.com/quickjs-ng/quickjs.git';

const subset = [
  'LICENSE',
  'builtin-array-fromasync.h',
  'builtin-iterator-zip-keyed.h',
  'builtin-iterator-zip.h',
  'cutils.h',
  'dtoa.c',
  'dtoa.h',
  'libregexp-opcode.h',
  'libregexp.c',
  'libregexp.h',
  'libunicode-table.h',
  'libunicode.c',
  'libunicode.h',
  'list.h',
  'quickjs-atom.h',
  'quickjs-c-atomics.h',
  'quickjs-opcode.h',
  'quickjs.c',
  'quickjs.h',
];

const packageDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const targetDir = path.join(packageDir, 'src', 'quickjs-ng');
const versionFile = path.join(packageDir, 'lib', 'src', 'quickjs_ng_version.dart');

// .............................................................................
// Steps

// Clones the tag into a fresh temporary folder and returns the folder.
const fetchTag = (tag) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'quickjs-ng-'));
  runCommand(
    `git clone --quiet --depth 1 --branch ${tag} ${repository} "${dir}"`,
  );
  return dir;
};

// Replaces the subset in src/quickjs-ng by the one of the checkout.
const copySubset = (checkoutDir) => {
  const missing = subset.filter(
    (file) => !fs.existsSync(path.join(checkoutDir, file)),
  );
  if (missing.length > 0) {
    throw new Error(`The tag lacks ${missing.join(', ')}`);
  }

  fs.rmSync(targetDir, { recursive: true, force: true });
  fs.mkdirSync(targetDir, { recursive: true });
  for (const file of subset) {
    fs.copyFileSync(path.join(checkoutDir, file), path.join(targetDir, file));
  }
};

// Reads the version that quickjs.h declares, e.g. 0.17.0.
const readVersion = () => {
  const header = fs.readFileSync(path.join(targetDir, 'quickjs.h'), 'utf8');
  const part = (name) => {
    const match = header.match(new RegExp(`#define QJS_VERSION_${name} (\\d+)`));
    if (!match) throw new Error(`quickjs.h declares no QJS_VERSION_${name}`);
    return match[1];
  };
  return `${part('MAJOR')}.${part('MINOR')}.${part('PATCH')}`;
};

// Writes the version into the constant of the Dart binding.
const writeVersion = (version) => {
  const source = fs.readFileSync(versionFile, 'utf8');
  const updated = source.replace(
    /const String quickjsNgVersion = '[^']*';/,
    `const String quickjsNgVersion = '${version}';`,
  );
  fs.writeFileSync(versionFile, updated);
};

// .............................................................................
// Main

// The tag goes into a shell command, so it must be a plain tag name.
const tag = process.argv[2];
if (!tag || !/^[A-Za-z0-9][\w.-]*$/.test(tag)) {
  console.log(yellow('Usage: node tool/update-quickjs-ng.js <tag>'));
  process.exit(1);
}

let checkoutDir;
try {
  console.log(gray(`Fetch QuickJS-ng ${tag}`));
  checkoutDir = fetchTag(tag);

  console.log(gray('Copy the library subset to src/quickjs-ng'));
  copySubset(checkoutDir);

  const version = readVersion();
  writeVersion(version);

  console.log(green(`✅ QuickJS-ng ${version} is in src/quickjs-ng.`));
  console.log(
    yellow(
      'Name the version in README.md, README.de.md and NOTICE, then run ' +
        'the tests.',
    ),
  );
} catch (error) {
  console.error(red(`❌ ${error.message}`));
  process.exit(1);
} finally {
  if (checkoutDir) fs.rmSync(checkoutDir, { recursive: true, force: true });
}
