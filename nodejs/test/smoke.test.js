// 工程自检：守住这个包的三条底线 —— 纯 ESM、零依赖、exports 不悬空。
// 实现模块（lexer.js / parser.js …）的单元测试请按同样的方式放在本目录下，
// 一个模块一个 `*.test.js`，公用的断言抽到 `test/helpers.js`。

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const srcDir = path.join(root, 'src');

async function readJson(rel) {
  return JSON.parse(await readFile(path.join(root, rel), 'utf8'));
}

async function listJs(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await listJs(full)));
    else if (entry.name.endsWith('.js')) out.push(full);
  }
  return out;
}

// import/export ... from 'x' | import 'x' | require('x')
const SPEC_RE =
  /(?:import|export)\b[^'"`]*?from\s*['"]([^'"]+)['"]|import\s*['"]([^'"]+)['"]|require\(\s*['"]([^'"]+)['"]\s*\)/g;

function specifiersOf(code) {
  const out = [];
  for (const m of code.matchAll(SPEC_RE)) out.push(m[1] ?? m[2] ?? m[3]);
  return out;
}

describe('package.json', () => {
  test('declares ESM', async () => {
    const pkg = await readJson('package.json');
    assert.equal(pkg.type, 'module');
  });

  test('has no dependencies at all', async () => {
    const pkg = await readJson('package.json');
    assert.equal(pkg.dependencies, undefined, 'runtime dependencies must stay empty');
    assert.equal(pkg.devDependencies, undefined, 'devDependencies must stay empty');
  });

  test('every exports entry points to a real file', async () => {
    const pkg = await readJson('package.json');
    const entry = pkg.exports['.'];
    assert.ok(entry, 'missing "." export');
    for (const [cond, rel] of Object.entries(entry)) {
      await access(path.join(root, rel)).catch(() => {
        throw new Error(`exports["."].${cond} -> ${rel} does not exist`);
      });
    }
  });
});

describe('src/', () => {
  test('index.js is importable as ESM', async () => {
    const mod = await import('../src/index.js');
    assert.equal(typeof mod, 'object');
  });

  test('imports nothing but node: builtins and relative paths', async () => {
    const files = await listJs(srcDir);
    assert.ok(files.length > 0, 'no source file found under src/');
    for (const file of files) {
      const code = await readFile(file, 'utf8');
      for (const spec of specifiersOf(code)) {
        const internal = spec.startsWith('node:') || spec.startsWith('./') || spec.startsWith('../');
        assert.ok(
          internal,
          `${path.relative(root, file)} imports "${spec}" — third-party deps are not allowed`,
        );
      }
    }
  });
});
