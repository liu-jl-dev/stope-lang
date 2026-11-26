#!/usr/bin/env bash
# 纯 javac 构建（零第三方依赖）。从任意目录调用均可。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
OUT="out"
rm -rf "$OUT" && mkdir -p "$OUT"

find stope tests demo -name '*.java' -print > "$OUT/sources.txt"
javac -encoding UTF-8 -d "$OUT" @"$OUT/sources.txt"

echo "编译完成: $HERE/$OUT"
