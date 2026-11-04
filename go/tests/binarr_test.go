package tests

import (
	"testing"

	"stope"
)

// 二进制数组解析 + 常量折叠矩阵：golden_binarr.txt（86 条）。

var baCases = []string{
	"", " ", "a", "ab", "b 0100 0001", "b 01000001", "B 1", "o 101", "O 7",
	"d 65", "d 300", "D 255 0", "x 41", "x ff FF", "X 0f", "41", "4_1", "_41",
	"01 02", "  01   02  ", "x zz", "z", "b", "d", "b 2", "o 8", "0 1",
	"9999999999999999999999", "d 2147483647", "d 2147483648", "ff",
}

// fbVal 折叠结果的紧凑写法，与 C++ 的 fmtValue 一致。
func fbVal(e stope.Node) string {
	if e == nil {
		return "null"
	}
	switch n := e.(type) {
	case *stope.NullExpr:
		return "Null"
	case *stope.BoolExpr:
		if n.Value {
			return "true"
		}
		return "false"
	case *stope.IntExpr:
		return strconvI64(n.Value)
	case *stope.FloatExpr:
		return stope.FmtG(n.Value)
	case *stope.BinArrExpr:
		return "[" + stope.FmtBytes(n.Value) + "]"
	case *stope.StringExpr:
		return "\"" + n.Value + "\""
	}
	return "?"
}

func mkInt(v int64) stope.Node {
	return &stope.IntExpr{NodeBase: stope.NodeBase{Line_: 1}, Value: v}
}
func mkFloat(v float64) stope.Node {
	return &stope.FloatExpr{NodeBase: stope.NodeBase{Line_: 1}, Value: v}
}
func mkBool(v bool) stope.Node {
	return &stope.BoolExpr{NodeBase: stope.NodeBase{Line_: 1}, Value: v}
}
func mkNull() stope.Node { return &stope.NullExpr{NodeBase: stope.NodeBase{Line_: 1}} }
func mkStr(v string) stope.Node {
	return &stope.StringExpr{NodeBase: stope.NodeBase{Line_: 1}, Value: v}
}
func mkBin(v []byte) stope.Node {
	return &stope.BinArrExpr{NodeBase: stope.NodeBase{Line_: 1}, Value: v}
}

func fb(name string, op stope.TokenType, l, r stope.Node) string {
	e := &stope.BinaryOpExpr{NodeBase: stope.NodeBase{Line_: 1}, LeftExpr: l, Op: op, RightExpr: r}
	o := stope.Optimize(e)
	folded := 0
	if _, isBin := o.(*stope.BinaryOpExpr); isBin {
		folded = 0
	} else {
		folded = 1
	}
	return "FB\t" + name + "\t" + strconvI(folded) + "\t" + fbVal(o)
}

func fu(name string, op stope.TokenType, v stope.Node) string {
	e := &stope.UnaryOpExpr{NodeBase: stope.NodeBase{Line_: 1}, Op: op, Expr: v}
	o := stope.Optimize(e)
	folded := 0
	if _, isUn := o.(*stope.UnaryOpExpr); isUn {
		folded = 0
	} else {
		folded = 1
	}
	return "FU\t" + name + "\t" + strconvI(folded) + "\t" + fbVal(o)
}

func binarrDumpAll() []string {
	var out []string
	// ---- BA：二进制数组解析 ----
	for _, tc := range baCases {
		var buf []byte
		ok := (&stope.BinaryArrayParser{}).ParseBinaryArray(tc, &buf)
		status := "ok"
		if ok != stope.RSuccess {
			status = "err"
		}
		out = append(out, "BA\t"+tc+"\t"+status+"\t["+stope.FmtBytes(buf)+"]")
	}
	// ---- FB：二元折叠 ----
	out = append(out, fb("+", stope.TAdd, mkInt(1), mkInt(2)))
	out = append(out, fb("-", stope.TSub, mkInt(5), mkInt(3)))
	out = append(out, fb("*", stope.TMul, mkInt(2), mkInt(3)))
	out = append(out, fb("/", stope.TDiv, mkInt(7), mkInt(2)))
	out = append(out, fb("/", stope.TDiv, mkInt(6), mkInt(3)))
	out = append(out, fb("/", stope.TDiv, mkInt(1), mkInt(0)))
	out = append(out, fb("idiv", stope.TIDiv, mkInt(7), mkInt(2)))
	out = append(out, fb("%", stope.TMod, mkInt(7), mkInt(2)))
	out = append(out, fb("^", stope.TPow, mkInt(2), mkInt(10)))
	out = append(out, fb("^", stope.TPow, mkInt(2), mkInt(-1)))
	out = append(out, fb("+", stope.TAdd, mkFloat(1.5), mkInt(1)))
	out = append(out, fb("+", stope.TAdd, mkInt(stope.Int64Max), mkInt(1)))
	out = append(out, fb("*", stope.TMul, mkInt(stope.Int64Max), mkInt(2)))
	out = append(out, fb("+", stope.TAdd, mkBool(true), mkBool(true)))
	out = append(out, fb("+", stope.TAdd, mkStr("ab"), mkStr("cd")))
	out = append(out, fb("*", stope.TMul, mkStr("ab"), mkInt(3)))
	out = append(out, fb("*", stope.TMul, mkInt(3), mkStr("ab")))
	out = append(out, fb("*", stope.TMul, mkStr(""), mkInt(1000000)))
	out = append(out, fb("*", stope.TMul, mkStr("ab"), mkInt(-1)))
	out = append(out, fb("*", stope.TMul, mkFloat(1.5), mkStr("ab")))
	out = append(out, fb("+", stope.TAdd, mkBin([]byte{1}), mkBin([]byte{2})))
	out = append(out, fb("*", stope.TMul, mkBin([]byte{1}), mkInt(3)))
	out = append(out, fb("+", stope.TAdd, mkNull(), mkInt(5)))
	out = append(out, fb("+", stope.TAdd, mkInt(5), mkNull()))
	out = append(out, fb("+", stope.TAdd, mkNull(), mkNull()))
	out = append(out, fb("-", stope.TSub, mkNull(), mkInt(5)))
	out = append(out, fb("-", stope.TSub, mkInt(5), mkNull()))
	out = append(out, fb("-", stope.TSub, mkNull(), mkNull()))
	out = append(out, fb("*", stope.TMul, mkNull(), mkInt(5)))
	out = append(out, fb("^", stope.TPow, mkNull(), mkInt(5)))
	out = append(out, fb("==", stope.TEQ, mkNull(), mkNull()))
	out = append(out, fb("==", stope.TEQ, mkNull(), mkInt(1)))
	out = append(out, fb("!=", stope.TNE, mkNull(), mkInt(1)))
	out = append(out, fb("<", stope.TLT, mkNull(), mkInt(1)))
	out = append(out, fb("==", stope.TEQ, mkBool(true), mkBool(true)))
	out = append(out, fb("==", stope.TEQ, mkBool(true), mkInt(1)))
	out = append(out, fb("==", stope.TEQ, mkInt(1), mkFloat(1.0)))
	out = append(out, fb("==", stope.TEQ, mkStr("a"), mkStr("a")))
	out = append(out, fb("<", stope.TLT, mkInt(1), mkInt(2)))
	out = append(out, fb("<", stope.TLT, mkBool(true), mkInt(2)))
	out = append(out, fb("<=", stope.TLE, mkFloat(1.5), mkFloat(1.5)))
	out = append(out, fb(">", stope.TGT, mkInt(2), mkInt(1)))
	out = append(out, fb(">=", stope.TGE, mkInt(2), mkInt(2)))
	out = append(out, fb("and", stope.TAnd, mkInt(1), mkInt(0)))
	out = append(out, fb("or", stope.TOr, mkInt(0), mkStr("a")))
	// ---- FU：一元折叠 ----
	out = append(out, fu("-", stope.TSub, mkBool(true)))
	out = append(out, fu("-", stope.TSub, mkBool(false)))
	out = append(out, fu("-", stope.TSub, mkInt(5)))
	out = append(out, fu("-", stope.TSub, mkFloat(1.5)))
	out = append(out, fu("-", stope.TSub, mkInt(stope.Int64Min)))
	out = append(out, fu("!", stope.TNot, mkNull()))
	out = append(out, fu("!", stope.TNot, mkInt(0)))
	out = append(out, fu("!", stope.TNot, mkFloat(0.0)))
	out = append(out, fu("!", stope.TNot, mkInt(5)))
	out = append(out, fu("!", stope.TNot, mkStr("")))
	return out
}

func TestGoldenBinarr(t *testing.T) {
	var want []string
	for _, line := range splitLines(readText(t, "golden_binarr.txt")) {
		if line != "" {
			want = append(want, line)
		}
	}
	got := binarrDumpAll()
	rep := NewReport(t)
	rep.CheckInt("golden_binarr.txt", "行数", len(want), len(got))
	n := len(want)
	if len(got) < n {
		n = len(got)
	}
	for i := 0; i < n; i++ {
		rep.Check("#"+strconvI(i+1), "行", want[i], got[i])
	}
	t.Logf("二进制数组+折叠：golden_binarr.txt %d 条，断言 %d 条，失败 %d 条",
		len(want), rep.Passed, rep.Failed)
}
