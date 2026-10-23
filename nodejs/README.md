# stope (Node.js)

Stope 语言的 Node.js 实现。**零第三方依赖**，测试用 Node 内置的 `node:test` 运行器。

需要 Node >= 20（覆盖率阈值门禁需 >= 22.8）。当前处于骨架阶段，实现模块尚未落地。

## 使用

无需 `npm install` —— 这个包没有任何依赖。

```js
import { Lexer } from '@liu-jl-dev/stope';
```

本地开发时直接引用源码：

```js
import { Lexer } from './src/index.js';
```

## 目录

```
nodejs/
├── package.json      # 纯 ESM；exports / files / engines 都在这里声明
├── .editorconfig     # 与仓库 .gitattributes 一致：LF 行尾
├── src/
│   ├── index.js      # 唯一公共入口，只做 re-export
│   └── index.d.ts    # 手写类型声明（不引 TypeScript 工具链）
└── test/
    └── smoke.test.js # 工程自检：ESM / 零依赖 / exports 不悬空
```

## 测试

| 目的 | 命令 |
| --- | --- |
| 跑全部测试 | `npm test` |
| 单文件 | `node --test test/lexer.test.js` |
| 按名字过滤 | `node --test --test-name-pattern="Lexer"` |
| 自动重跑 | `npm run test:watch` |
| 覆盖率 + 阈值门禁 | `npm run test:cov` |
| 语法自检 | `npm run check` |

`npm test` 展开后就是 `node --test "test/**/*.test.js"`。glob 必须加双引号，
否则 shell 会先展开成空格分隔的文件列表。

覆盖率标志至今仍是 `--experimental-test-coverage`（不是 `--test-coverage`），
输出格式仍可能随 Node 版本变动。`test:cov` 额外用 `--test-coverage-include="src/**"`
把统计范围限定在源码目录 —— 不限定的话，运行器进程里加载的其他文件也会被算进
分母，门槛形同虚设。阈值（行 80% / 分支 70%）不达标会让进程退出码为 1。

## 新增一个模块

1. 实现放 `src/<module>.js`；
2. 在 `src/index.js` 加一行 `export { X } from './<module>.js';`；
3. 测试放 `test/<module>.test.js`。

测试文件的写法：

```js
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { Lexer } from '../src/lexer.js';

describe('Lexer', () => {
  test('tokenize integer literal', () => {
    assert.equal(new Lexer('123').next().value, 123);
  });
});
```

## 约定

- **零依赖是硬约束**：`package.json` 里不得出现 `dependencies` / `devDependencies`，
  `src/` 下只允许 import `node:` 内置模块和相对路径。`test/smoke.test.js` 会自动检查这两条。
- **纯 ESM**：`"type": "module"`，源码里不用 `require`、不写 `.cjs`。
- **断言分族**：与 C++ 侧一致 —— 每个模块一组语义化断言（如 `expectToken`），
  公用断言抽到 `test/helpers.js`，期望值改一处即可。
- **golden 数据由 C++ 侧 dump 生成**，不手写；比对前统一剥掉 `\r`（Windows 行尾差异）。
- **`exports` 封闭包内路径**：外部只能从包根导入，深引用 `pkg/src/x.js` 会失败，这是刻意的。

## 发布

```sh
npm pack --dry-run   # 先确认打进去的文件（test/ 不应在内）
npm publish --access public
```

`files` 白名单只放行 `src`、`README.md`、`LICENSE`。
