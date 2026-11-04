package tests

import (
	"math"
	"strings"
	"testing"

	"stope"
	"stope/basicvm"
)

// 参考执行器：值语义 + 两条驱动路径。没有 golden 数据。
//
// 1. Run 与 Step 一致 —— 两条独立实现，连走的条数都一样；
// 2. 与另外五份实现同一种答案 —— 算术 / 序列 / 真值 / 除零 / 回绕 / 相等。

// ---------------- 夹具 ----------------

// noArgs 这组用例都不用 args / argc；真被取到就报错。
type noArgs struct{}

func (noArgs) At(s *basicvm.State, _ basicvm.Value) basicvm.Value {
	s.Error("args not provided in this test. ")
	return nil
}
func (noArgs) Num() int { return 0 }

type arrayArgs struct{ data []basicvm.Value }

func (a arrayArgs) At(s *basicvm.State, key basicvm.Value) basicvm.Value {
	idx, ok := key.(int64)
	if !ok || idx < 0 || int(idx) >= len(a.data) {
		s.Error("argument out of range. ")
		return nil
	}
	return a.data[idx]
}
func (a arrayArgs) Num() int { return len(a.data) }

// compile 编译；成功返回 (Program, nil)，失败返回 (nil, 错误列表)。
func compile(t *testing.T, src string, custom *stope.CustomOpcodeConfig) (*stope.Program, []string) {
	t.Helper()
	ps := stope.NewParser(stope.NewLexer(src), custom)
	tree := &stope.Prog{}
	ps.ParseProgram(tree)
	out := stope.NewProgram()
	c := stope.NewCompiler(custom)
	c.Compile(tree, out, nil)
	var errs []string
	errs = append(errs, ps.Errors...)
	errs = append(errs, c.Errors...)
	if len(errs) > 0 {
		return nil, errs
	}
	return out, nil
}

// state 装配 State 但不执行 —— 宿主函数要先往 Variables 里塞值。
func newState(prog *stope.Program, args basicvm.Arguments) *basicvm.State {
	s := &basicvm.State{}
	s.SetApi(basicvm.NewApi())
	s.SetProgram(prog)
	s.SetArguments(args)
	return s
}

// build 编译并执行；失败返回 (nil, 错误列表)。
func build(t *testing.T, src string, args basicvm.Arguments, custom *stope.CustomOpcodeConfig) (*basicvm.State, []string) {
	t.Helper()
	prog, errs := compile(t, src, custom)
	if prog == nil {
		return nil, errs
	}
	s := newState(prog, args)
	s.Run()
	return s, nil
}

// fmtV 紧凑写法：null / 整数 / 浮点（无小数点时补 .0）/ 字符串原样 / 字节数组 [1,2]。
func fmtV(v basicvm.Value) string {
	switch x := v.(type) {
	case nil:
		return "null"
	case bool:
		if x {
			return "1"
		}
		return "0" // 值层面不该出现 bool，出现就是没归一
	case int64:
		return strconvI64(x)
	case float64:
		if math.IsNaN(x) {
			return "nan"
		}
		if math.IsInf(x, 1) {
			return "inf"
		}
		if math.IsInf(x, -1) {
			return "-inf"
		}
		s := stope.FmtG(x)
		if !strings.ContainsAny(s, ".e") {
			s += ".0"
		}
		return s
	case string:
		return x
	case []byte:
		parts := make([]string, len(x))
		for i, b := range x {
			parts[i] = strconvI(int(b))
		}
		return "[" + strings.Join(parts, ",") + "]"
	}
	return "<other>"
}

func fmtReturns(s *basicvm.State) string {
	parts := make([]string, len(s.Returns))
	for i, v := range s.Returns {
		parts[i] = fmtV(v)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// msgOnly "3 Div: msg" → "msg"：前缀（下标 + 指令名）由实现决定，跨实现只比消息。
func msgOnly(e string) string {
	i := strings.Index(e, ": ")
	if i < 0 {
		return e
	}
	return e[i+2:]
}

// instCount 产物里有几条指令（跳过操作数格）—— 与「走了几步」对照用。
func instCount(p *stope.Program) int {
	n := 0
	i := 0
	ops := p.Opcodes
	for i < len(ops) {
		n++
		if stope.OpcodeHasArg(ops[i]) {
			i += 2
		} else {
			i++
		}
	}
	return n
}

func returnsCase(t *testing.T, rep *Report, cid, src, want string) {
	s, errs := build(t, src, noArgs{}, nil)
	if s == nil {
		rep.Fail(cid, "编译失败："+src+" | "+strings.Join(errs, ""))
		return
	}
	rep.Check(cid, "returns", want, fmtReturns(s))
	rep.Check(cid, "errors", "", strings.Join(s.Errors, "|"))
}

func errsCase(t *testing.T, rep *Report, cid, src, wantMsg string) {
	// 断言报错：只比 ": " 之后的正文（前缀由实现自定）。
	s, errs := build(t, src, noArgs{}, nil)
	if s == nil {
		rep.Fail(cid, "编译失败："+src+" | "+strings.Join(errs, ""))
		return
	}
	rep.CheckInt(cid, "错误条数", 1, len(s.Errors))
	got := "<无错误>"
	if len(s.Errors) > 0 {
		got = msgOnly(s.Errors[0])
	}
	rep.Check(cid, "错误消息", wantMsg, got)
}

// ---------------- 用例 ----------------

func TestVM(t *testing.T) {
	rep := NewReport(t)

	// ==================== 布尔就是整数 1 / 0 ====================
	returnsCase(t, rep, "V-06", "return true;", "[1]")
	returnsCase(t, rep, "V-06b", "return false;", "[0]")
	returnsCase(t, rep, "V-06c", "let t = true; let f = false; return t + f + (1 == 1);", "[2]")
	returnsCase(t, rep, "V-06d", "let a = 1; let b = 2; return a < b;", "[1]")

	// ==================== 整数幂：回绕 / 负指数转浮点 ====================
	returnsCase(t, rep, "V-07", "let a = 2; let b = 64; return a ^ b;", "[0]")
	returnsCase(t, rep, "V-07b", "let a = 2; return a ^ -1;", "[0.5]")
	returnsCase(t, rep, "V-07c", "let a = -8.0; let b = 0.5; return a ^ b;", "[nan]")

	// ==================== 序列重复与拼接 ====================
	returnsCase(t, rep, "V-08", "let s = \"ab\"; return s * 2;", "[abab]")
	returnsCase(t, rep, "V-08b", "let s = \"ab\"; return 2 * s;", "[abab]")
	returnsCase(t, rep, "V-08c", "let b = 'd 1 2'; return b * 2;", "[[1,2,1,2]]")
	errsCase(t, rep, "V-08d", "let s = \"ab\"; let n = -1; return s * n;",
		"\"Mul\" cannot repeat a sequence by a negative number. ")
	returnsCase(t, rep, "V-08e", "let a = \"x\"; let b = \"y\"; return a + b;", "[xy]")
	returnsCase(t, rep, "V-08f", "let a = 'd 1'; let b = 'd 2'; return a + b;", "[[1,2]]")
	errsCase(t, rep, "V-08g", "let b = 'd 1'; let n = -2; return b * n;",
		"\"Mul\" cannot repeat a sequence by a negative number. ")

	// ==================== 真值 ====================
	returnsCase(t, rep, "V-09", "let s = \"\"; if s { return 1; } return 2;", "[2]")
	returnsCase(t, rep, "V-09b", "let s = \"x\"; if s { return 1; } return 2;", "[1]")
	returnsCase(t, rep, "V-09c", "let b = 'd'; if b { return 1; } return 2;", "[2]")

	// ==================== 除零 ====================
	errsCase(t, rep, "V-10", "let a = 1; let b = 0; return a / b;", "\"Div\" division by zero. ")
	errsCase(t, rep, "V-10b", "let a = 1; let b = 0; return a idiv b;", "\"IDiv\" division by zero. ")
	errsCase(t, rep, "V-10c", "let a = 1; let b = 0; return a % b;", "\"Mod\" division by zero. ")
	returnsCase(t, rep, "V-10d", "let a = 1.0; let b = 0; return a / b;", "[inf]")
	returnsCase(t, rep, "V-10e", "let a = 0.0; let b = 0; return a / b;", "[nan]")
	returnsCase(t, rep, "V-10f", "let a = 1.5; let b = 0; return a % b;", "[nan]")
	returnsCase(t, rep, "V-10g", "let a = -7.0; let b = 2.0; return a % b;", "[-1.0]")

	// ==================== ! 只接受 null / 整数 / 浮点 ====================
	errsCase(t, rep, "V-11", "let s = \"abc\"; return !s;",
		"\"Not\" can only operate on integer or float. ")

	// ==================== INT64_MIN 的三个角落 ====================
	returnsCase(t, rep, "V-12", "let m = 0 - 9223372036854775807 - 1; return -m;",
		"[-9223372036854775808]")
	returnsCase(t, rep, "V-12b", "let m = 0 - 9223372036854775807 - 1; return m idiv -1;",
		"[-9223372036854775808]")
	returnsCase(t, rep, "V-12c", "let m = 0 - 9223372036854775807 - 1; return m % -1;", "[0]")

	// ==================== idiv：含浮点仍向零取整，但保持浮点 ====================
	returnsCase(t, rep, "V-13", "let a = 7; let b = 2; return a idiv b;", "[3]")
	returnsCase(t, rep, "V-13b", "let a = 7.5; let b = 2; return a idiv b;", "[3.0]")
	returnsCase(t, rep, "V-13c", "let a = 1.0; let b = 0; return a idiv b;", "[inf]")

	// ==================== 相等：类型不同一律不等 ====================
	returnsCase(t, rep, "V-15", "let a = \"1\"; let b = 1; return a == b;", "[0]")
	returnsCase(t, rep, "V-15b", "let a = null; let b = 0; return a == b;", "[0]")
	returnsCase(t, rep, "V-15c", "let a = 'd 1 2'; let b = 'd 1 2'; return a == b;", "[1]")
	returnsCase(t, rep, "V-15d", "let a = 'd 1'; let b = 'd 2'; return a == b;", "[0]")
	returnsCase(t, rep, "V-15e", "let a = \"ab\"; let n = 0; return a * n;", "[]")

	// ==================== 下标取码元 ====================
	returnsCase(t, rep, "V-15f", "let b = 'd 1 2'; return b[1];", "[2]")
	// 取的是 UTF-16 码元：非 BMP 字符（U+1F600）给出高位代理 55357
	returnsCase(t, rep, "V-15g", "let s = \"\U0001F600\"; return s[0];", "[55357]")
	errsCase(t, rep, "V-15h", "let b = 'd 1'; return b[5];", "index out of range. ")

	hostFunctions(t, rep)
	arguments(t, rep)
	errorIndex(t, rep)
	customOpcode(t, rep)
	runStepEquivalence(t, rep)

	t.Logf("参考执行器：断言 %d 条，失败 %d 条", rep.Passed, rep.Failed)
}

func hostFunctions(t *testing.T, rep *Report) {
	// 宿主函数：一个值，直接放变量槽
	prog, errs := compile(t, "return f(1, 2);", nil)
	if prog == nil {
		rep.Fail("V-14", "编译失败："+strings.Join(errs, ""))
	} else {
		s := newState(prog, noArgs{})
		// 未声明就被调用 → 编译器隐式登记进 exports；槽位号由编译器分配，不能写死
		idx, _ := prog.ExportOf("f")
		s.Variables[idx] = basicvm.HostFunction(func(argv []basicvm.Value) basicvm.Value {
			return argv[0].(int64) + argv[1].(int64)
		})
		rc := s.Run()
		rep.Check("V-14", "run 返回", "Success", resultName(rc))
		rep.Check("V-14", "returns", "[3]", fmtReturns(s))
	}

	// 宿主函数返回 bool：归一成整数（Stope 没有布尔值类型）
	prog2, errs2 := compile(t, "return g();", nil)
	if prog2 == nil {
		rep.Fail("V-14b", "编译失败："+strings.Join(errs2, ""))
	} else {
		s2 := newState(prog2, noArgs{})
		idx, _ := prog2.ExportOf("g")
		s2.Variables[idx] = basicvm.HostFunction(func(_ []basicvm.Value) basicvm.Value { return true })
		s2.Run()
		rep.Check("V-14b", "returns", "[1]", fmtReturns(s2))
		_, isInt := s2.Returns[0].(int64)
		rep.CheckTrue("V-14b", "returns[0] 类型为 int64", isInt)
	}

	// Call 到非函数
	s3, _ := build(t, "let x = 1; return x(2);", noArgs{}, nil)
	if s3 == nil {
		rep.Fail("V-17", "编译失败")
	} else {
		rep.CheckInt("V-17", "错误条数", 1, len(s3.Errors))
		got := "<无错误>"
		if len(s3.Errors) > 0 {
			got = msgOnly(s3.Errors[0])
		}
		rep.Check("V-17", "错误消息", "\"Call\" can only call a function. ", got)
	}
}

func arguments(t *testing.T, rep *Report) {
	s, _ := build(t, "return argc + args[0];", arrayArgs{[]basicvm.Value{int64(2)}}, nil)
	if s == nil {
		rep.Fail("V-18", "编译失败")
	} else {
		rep.Check("V-18", "returns", "[3]", fmtReturns(s)) // argc(1) + args[0](2)
	}

	s2, _ := build(t, "return argc;", nil, nil)
	if s2 == nil {
		rep.Fail("V-19", "编译失败")
	} else {
		rep.CheckInt("V-19", "错误条数", 1, len(s2.Errors))
		got := "<无错误>"
		if len(s2.Errors) > 0 {
			got = msgOnly(s2.Errors[0])
		}
		rep.Check("V-19", "错误消息", "no args. ", got)
	}

	s3, _ := build(t, "return args[5];", arrayArgs{[]basicvm.Value{int64(1)}}, nil)
	if s3 == nil {
		rep.Fail("V-20", "编译失败")
	} else {
		rep.CheckInt("V-20", "错误条数", 1, len(s3.Errors))
		got := "<无错误>"
		if len(s3.Errors) > 0 {
			got = msgOnly(s3.Errors[0])
		}
		rep.Check("V-20", "错误消息", "argument out of range. ", got)
	}

	// 宿主 At() 里报错之后执行器必须停：错误进同一个 errors，且定位到 GetArg 那条
	prog, _ := compile(t, "return args[0];", nil)
	if prog == nil {
		rep.Fail("V-04", "编译失败")
		return
	}
	opts := newState(prog, noArgs{})
	rc := opts.Run()
	rep.Check("V-04", "run 返回", "Error", resultName(rc))
	rep.CheckInt("V-04", "错误条数", 1, len(opts.Errors))
	got := "<无错误>"
	if len(opts.Errors) > 0 {
		got = msgOnly(opts.Errors[0])
	}
	rep.Check("V-04", "错误消息", "args not provided in this test. ", got)
	stoppedOnGetArg := opts.I < len(prog.Opcodes) && prog.Opcodes[opts.I] == int(stope.OpGetArg)
	rep.CheckTrue("V-04", "停机在 GetArg 上", stoppedOnGetArg)
}

func errorIndex(t *testing.T, rep *Report) {
	// 错误串前缀是 "<指令下标>: " —— 下标就是出错那条指令在产物里的位置。
	s, _ := build(t, "return 1 / 0;", noArgs{}, nil)
	if s == nil || len(s.Errors) != 1 {
		rep.Fail("V-16", "`return 1 / 0;` 应当恰好报一条错")
		return
	}
	// 产物是 PushInt(0) PushInt(1) Div Return(1) —— Div 在下标 4
	rep.CheckTrue("V-16", "错误串形如 \"4: ...\"："+s.Errors[0],
		strings.HasPrefix(s.Errors[0], "4: \"Div\" division by zero. "))
}

func customOpcode(t *testing.T, rep *Report) {
	// 自定义指令（编号 >= 33）能跑、能报错，且 SetOpcode 会把中间补齐。
	cfg := stope.NewCustomOpcodeConfig()
	cfg.AddCustomOpcode("my:boom", stope.KFirstCustomOpcode, 0)
	prog, errs := compile(t, "my:boom();", cfg)
	if prog == nil {
		rep.Fail("V-05", "编译失败："+strings.Join(errs, ""))
		return
	}

	boom := func(s *basicvm.State) { s.Error("boom. ") }

	api := basicvm.NewApi()
	api.SetOpcode(stope.KFirstCustomOpcode, boom)
	s := &basicvm.State{}
	s.SetApi(api)
	s.SetProgram(prog)
	s.SetArguments(noArgs{})
	rc := s.Run()
	rep.Check("V-05", "run 返回", "Error", resultName(rc))
	rep.CheckInt("V-05", "错误条数", 1, len(s.Errors))
	rep.Check("V-05", "错误全文", "0: boom. ", strings.Join(s.Errors, "|"))

	// 跳号注册：33 是刚注册的，34/35 必须补成占位函数而不是留空
	api2 := basicvm.NewApi()
	rep.CheckInt("V-05b", "内置表长度", stope.KFirstCustomOpcode, len(api2.OpMap))
	api2.SetOpcode(stope.KFirstCustomOpcode+2, boom)
	rep.CheckInt("V-05b", "补齐后长度", stope.KFirstCustomOpcode+3, len(api2.OpMap))
}

func resultName(rc stope.Result) string {
	if rc == stope.RSuccess {
		return "Success"
	}
	return "Error"
}

func runStepEquivalence(t *testing.T, rep *Report) {
	// Run 与 Step 是两份独立实现（热循环不套函数调用）。同一批程序跑两遍：
	// 返回值必须一致，顺序执行时指令条数也必须一致。
	type vcase struct {
		src    string
		linear bool
	}
	cases := []vcase{
		{"return 1 + 2 * 3;", true},
		{"let a = 1; while a < 5 { a = a + 1; } return a;", false},
		{"let s = 0; let i = 0; while i < 10 { if i % 2 == 0 { s = s + i; } i = i + 1; } return s;", false},
		{"let a = 1; let b = 2; return a < b and b < 3;", false},
		{"if 1 { return 10; } else { return 20; }", false},
		{"let x = 0; while { x = x + 1; if x > 3 { break; } } return x;", false},
	}

	for _, c := range cases {
		cid := "V-21 " + c.src
		prog, errs := compile(t, c.src, nil)
		if prog == nil {
			rep.Fail("V-21", "编译失败："+c.src+" | "+strings.Join(errs, ""))
			continue
		}

		s1 := newState(prog, noArgs{})
		s1.Run()

		s2 := newState(prog, noArgs{})
		steps := 0
		for s2.I < len(prog.Opcodes) && s2.Step() == stope.RSuccess {
			steps++
			if steps > 100000 {
				break
			}
		}

		rep.Check(cid, "returns", fmtReturns(s1), fmtReturns(s2))
		rep.Check(cid, "errors", strings.Join(s1.Errors, "|"), strings.Join(s2.Errors, "|"))
		rep.CheckTrue(cid, "step 应把指令流走完", s2.I >= len(prog.Opcodes))
		rep.CheckInt(cid, "停机时 i", s1.I, s2.I)
		if c.linear {
			rep.CheckInt(cid, "步数应等于指令条数", instCount(prog), steps)
		}

		// 停机后再驱动一次：不执行指令、不追加错误（结束态与错误态都应如此）
		errBefore := len(s2.Errors)
		iBefore := s2.I
		again := s2.Step()
		rep.CheckTrue(cid, "停机后 step 返回 Success（什么都不做）", again == stope.RSuccess)
		rep.CheckInt(cid, "停机后 i 不变", iBefore, s2.I)
		rep.CheckInt(cid, "停机后 errors 不变", errBefore, len(s2.Errors))
	}
}
