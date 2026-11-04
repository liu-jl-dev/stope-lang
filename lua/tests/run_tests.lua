-- run_tests.lua —— 测试入口。任何 cwd 都能跑：
--   lua /e/lib/stope-lang/lua/tests/run_tests.lua
--
-- 分组与输出格式与 Python / GDScript / C# 的跑器同形。期望值全部来自
-- gdscript/test/data/ 的 golden 数据（执行器与嵌套深度两组例外），不需要 C++ 工具链。

-- ---- 定位自身，把 lua/ 与 tests/ 挂进 package.path（任何 cwd 都能跑）----
local src = debug.getinfo(1, "S").source
if string.sub(src, 1, 1) == "@" then
    src = string.sub(src, 2)
end
src = string.gsub(src, "\\", "/")
if src:sub(2, 2) == ":" then
    src = src:sub(1, 1):lower() .. src:sub(2) -- 统一盘符大小写
end
local script_dir = string.match(src, "^(.*)/[^/]+$") or "."
local lua_dir = string.match(script_dir, "^(.*)/tests$") or (script_dir .. "/..")
lua_dir = lua_dir:gsub("/lua/lua$", "/lua") -- 兜底
package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;"
    .. script_dir .. "/?.lua;" .. package.path

local golden = require("tests.golden")
local Report = require("tests.report")

local test_lexer = require("tests.test_lexer")
local test_binarr = require("tests.test_binarr")
local test_parser = require("tests.test_parser")
local test_compiler = require("tests.test_compiler")
local test_disasm = require("tests.test_disasm")
local test_stml = require("tests.test_stml")
local test_vm = require("tests.test_vm")

local function main()
    print("====================================================")
    print("Stope Lua 实现 —— 测试跑器")
    print("数据目录：" .. golden.locate_data_dir())
    print("====================================================")

    local groups = {
        { "词法（golden_lex.txt）", test_lexer.run },
        { "二进制数组 + 常量折叠（golden_binarr.txt）", test_binarr.run },
        { "语法（golden.txt）", test_parser.run },
        { "编译器（golden.txt）", test_compiler.run },
        { "嵌套深度上限", test_parser.run_depth },
        { "反汇编（golden_disasm.txt）", test_disasm.run },
        { "STML（stml_cases.txt + golden_stml.txt）", test_stml.run },
        { "参考执行器", test_vm.run },
    }

    local total_passed, total_failed = 0, 0
    local golden_counts = {}
    for i, group in ipairs(groups) do
        print()
        print(string.format("[%d/%d] %s", i, #groups, group[1]))
        local rep = Report.new()
        local ok, ex = pcall(group[2], rep)
        if not ok then
            rep:add_fail(group[1], "抛异常：" .. tostring(ex))
        end
        rep:dump()
        print(string.format("  （本组）  断言 %d 条，失败 %d 条", rep:total(), rep.failed))
        total_passed = total_passed + rep.passed
        total_failed = total_failed + rep.failed
        if rep.case_count then
            golden_counts[#golden_counts + 1] = group[1] .. "：" .. rep.case_count .. " 条用例"
        end
    end

    print()
    print("====================================================")
    for _, c in ipairs(golden_counts) do
        print("  " .. c)
    end
    print("====================================================")
    if total_failed == 0 then
        print(string.format("全部通过：共 %d 条断言", total_passed))
        print("====================================================")
        return 0
    end
    print(string.format("失败 %d 条 / 共 %d 条断言", total_failed, total_passed + total_failed))
    print("====================================================")
    return 1
end

os.exit(main())
