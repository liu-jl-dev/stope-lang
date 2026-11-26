#!/usr/bin/env bash
# 运行 golden 测试。数据真源 gdscript/test/data/，cwd 需在仓库根（脚本自动切）。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
if [ ! -d "$HERE/out/tests" ]; then "$HERE/build.sh"; fi
cd "$ROOT"
java -cp "$HERE/out" tests.TestMain
