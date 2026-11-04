-- report.lua —— 极简断言与汇总。**不是测试框架**：只有「比一下、记一笔」。

local Report = {}
Report.__index = Report
Report.MAX_SHOWN = 40

function Report.new()
    return setmetatable({ passed = 0, failed = 0, messages = {} }, Report)
end

function Report:total()
    return self.passed + self.failed
end

local function show(s)
    if s == nil or s == "" then return "<空>" end
    local t = string.gsub(s, "\n", "\\n")
    if #t > 300 then
        return string.sub(t, 1, 300) .. "…"
    end
    return t
end

function Report:check(case_id, field, want, got)
    if want == got then
        self.passed = self.passed + 1
        return
    end
    self.failed = self.failed + 1
    if #self.messages < Report.MAX_SHOWN then
        self.messages[#self.messages + 1] = string.format(
            "  FAIL %s [%s]\n        期望: %s\n        实际: %s",
            case_id, field, show(want), show(got))
    elseif #self.messages == Report.MAX_SHOWN then
        self.messages[#self.messages + 1] = "  ... 更多失败已省略"
    end
end

function Report:check_int(case_id, field, want, got)
    self:check(case_id, field, string.format("%d", want), string.format("%d", got))
end

function Report:check_true(case_id, what, ok)
    if ok then
        self.passed = self.passed + 1
        return
    end
    self.failed = self.failed + 1
    if #self.messages < Report.MAX_SHOWN then
        self.messages[#self.messages + 1] = string.format("  FAIL %s %s", case_id, what)
    end
end

function Report:add_fail(case_id, why)
    self.failed = self.failed + 1
    if #self.messages < Report.MAX_SHOWN then
        self.messages[#self.messages + 1] = string.format("  FAIL %s %s", case_id, why)
    end
end

function Report:dump()
    for _, m in ipairs(self.messages) do
        print(m)
    end
    self.messages = {}
end

return Report
