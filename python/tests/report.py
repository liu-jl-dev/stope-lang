"""极简断言与汇总。

**不是测试框架**：没有用例发现、没有 fixture、没有并行 —— 只有「比一下、记一笔」。
目标只有一个：输出与 GDScript 的 ``run_tests.gd``、C# 的 ``Runner`` 同形，
三条命令能横向对照。
"""


class Report:
    MAX_SHOWN = 40

    __slots__ = ("passed", "failed", "_messages")

    def __init__(self):
        self.passed = 0
        self.failed = 0
        self._messages: list[str] = []

    @property
    def total(self) -> int:
        return self.passed + self.failed

    def check(self, case_id: str, field: str, want: str, got: str) -> None:
        if want == got:
            self.passed += 1
            return
        self.failed += 1
        if len(self._messages) < self.MAX_SHOWN:
            self._messages.append(
                f"  FAIL {case_id} [{field}]\n"
                f"        期望: {show(want)}\n"
                f"        实际: {show(got)}")
        elif len(self._messages) == self.MAX_SHOWN:
            self._messages.append("  ... 更多失败已省略")

    def check_int(self, case_id: str, field: str, want: int, got: int) -> None:
        self.check(case_id, field, str(want), str(got))

    def check_true(self, case_id: str, what: str, ok: bool) -> None:
        if ok:
            self.passed += 1
            return
        self.failed += 1
        if len(self._messages) < self.MAX_SHOWN:
            self._messages.append(f"  FAIL {case_id} {what}")

    def add_fail(self, case_id: str, why: str) -> None:
        self.failed += 1
        if len(self._messages) < self.MAX_SHOWN:
            self._messages.append(f"  FAIL {case_id} {why}")

    def dump(self) -> None:
        for m in self._messages:
            print(m)
        self._messages.clear()


def show(s: str) -> str:
    if not s:
        return "<空>"
    t = s.replace("\n", "\\n")
    return t[:300] + "…" if len(t) > 300 else t
