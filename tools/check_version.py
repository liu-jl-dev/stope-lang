#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# check_version.py —— 校验版本号在全部落点的一致性。
#
# Stope 全仓共用一个版本号，落在八处（见 VERSION_SPOTS；Go 用 git tag，无版本字段）。手工改版本号时容易
# 漏改某一处，本脚本把它们全部取出来断言相等：
#
#   python tools/check_version.py            # 全部一致则退出码 0，否则 1
#   python tools/check_version.py 0.2.0      # 与期望值比较（发版前预检用）
#
# 零第三方依赖，只用标准库。新增版本落点时，在 VERSION_SPOTS 里加一行即可。
# 规则本身（主 / 次 / 修订号各在什么时候升）写在 CHANGELOG.md 的「版本规则」一节。
# ---------------------------------------------------------------------------

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# (相对路径, 正则)。正则需含一个捕获组，捕获版本号本身。
VERSION_SPOTS = [
    ("cpp/CMakeLists.txt", r"^project\(Stope VERSION (\S+)\)"),
    ("gdscript/addons/stope/plugin.cfg", r'^version="([^"]+)"'),
    ("nodejs/package.json", r'"version": "([^"]+)"'),
    ("csharp/Stope/Stope.csproj", r"<Version>([^<]+)</Version>"),
    ("python/stope/__init__.py", r'^__version__ = "([^"]+)"'),
    ("rust/Cargo.toml", r'^version = "([^"]+)"'),
    ("lua/stope/init.lua", r'^stope\.version = "([^"]+)"'),
    # CHANGELOG 取第一个「纯版本号」标题 —— [Unreleased] 里没有数字，天然被跳过。
    ("CHANGELOG.md", r"^## \[(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)\]"),
]


def main() -> int:
    expected = sys.argv[1] if len(sys.argv) > 1 else None
    found = {}  # 相对路径 -> 版本号
    missing = []

    for rel, pattern in VERSION_SPOTS:
        path = REPO / rel
        if not path.is_file():
            missing.append((rel, "文件不存在"))
            continue
        match = re.search(pattern, path.read_text(encoding="utf-8"), re.MULTILINE)
        if match:
            found[rel] = match.group(1)
        else:
            missing.append((rel, "模式未命中"))

    for rel, why in missing:
        print(f"缺失: {rel}（{why}）")

    if not found:
        print("失败: 一个落点都没取到，检查 REPO 是否指向仓库根")
        return 1

    distinct = sorted(set(found.values()))
    base_rel, base = next(iter(found.items()))  # C++ 是权威实现，拿它当基准
    for rel, ver in found.items():
        mark = "" if ver == base else f"  <-- 与 {base_rel} 的 {base} 不一致"
        print(f"{ver}  {rel}{mark}")

    if len(distinct) != 1:
        print(f"\n失败: {len(distinct)} 个不同版本号: {', '.join(distinct)}")
        return 1
    if expected is not None and distinct[0] != expected:
        print(f"\n失败: 版本号 {distinct[0]} != 期望 {expected}")
        return 1
    if missing:
        print(f"\n失败: {len(missing)} 处落点取不到版本号")
        return 1

    print(f"\n一致: {len(found)} 处落点均为 {distinct[0]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
