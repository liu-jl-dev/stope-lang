package tests

import (
	"strconv"
	"strings"
	"testing"

	"stope"
)

// 语法：golden.txt（224 条）+ 嵌套深度上限。
// 每条用例断言六件事：AST 形状串、语句行号序列、语法 / 词法错误条数与文案。
//
// ⚠ SRC 要解两层转义：golden 里存的是 E_(escUtf8(源码))，读文件时已解了外层的 E_，
// 这里再解一层 escUtf8。而 SHAPE / OUT 这些字段存的就是「转义后的形态」，只解一层。

type parserCase struct {
	SRC, SHAPE, LINES, PERR, PERRS, LEXERR, LEXERRS string
	Tree                                            *stope.Prog
}

func runParserCase(rec map[string]string) parserCase {
	src := unescape(rec["SRC"])
	fold := rec["FOLD"] == "1"

	lx := stope.NewLexer(src)
	ps := stope.NewParser(lx, CFG)
	ps.ConstFolding = fold
	tree := &stope.Prog{}
	ps.ParseProgram(tree)

	var lines []string
	for _, s := range tree.Stmts {
		lines = append(lines, strconv.Itoa(s.Line()))
	}
	return parserCase{
		SRC:     src,
		SHAPE:   stope.ShapeProg(tree),
		LINES:   strings.Join(lines, ","),
		PERR:    strconv.Itoa(len(ps.Errors)),
		PERRS:   joinEsc(ps.Errors),
		LEXERR:  strconv.Itoa(len(lx.Errors)),
		LEXERRS: joinEsc(lx.Errors),
		Tree:    tree,
	}
}

func readGoldenMain(t *testing.T) []map[string]string {
	cases := readGolden(t, "golden.txt", true)
	if len(cases) == 0 {
		t.Fatal("golden.txt 一条都没读到")
	}
	if len(cases) != 224 {
		t.Errorf("golden.txt 条数 = %d, want 224", len(cases))
	}
	return cases
}

func TestGoldenParser(t *testing.T) {
	cases := readGoldenMain(t)
	rep := NewReport(t)
	for _, rec := range cases {
		cid := rec["ID"]
		got := runParserCase(rec)
		rep.Check(cid, "SHAPE", rec["SHAPE"], got.SHAPE)
		rep.Check(cid, "LINES", rec["LINES"], got.LINES)
		rep.Check(cid, "PERR", rec["PERR"], got.PERR)
		rep.Check(cid, "PERRS", rec["PERRS"], got.PERRS)
		rep.Check(cid, "LEXERR", rec["LEXERR"], got.LEXERR)
		rep.Check(cid, "LEXERRS", rec["LEXERRS"], got.LEXERRS)
	}
	t.Logf("语法：golden.txt %d 条，断言 %d 条，失败 %d 条", len(cases), rep.Passed, rep.Failed)
}

// ---------------- 嵌套深度上限 ----------------
// 期望值不 dump：限额与错误文案是【四方约定】，所以按约定写死。

func depthSource(kind string, n int) string {
	// 与 GD 侧 _depth_case 的构造逐字一致：块里要有语句，否则永远进不到
	// parseExpr，深度计数根本没机会检查。
	switch kind {
	case "paren":
		return strings.Repeat("(", n) + "a" + strings.Repeat(")", n) + ";"
	case "block":
		return strings.Repeat("{", n) + "a;" + strings.Repeat("}", n)
	case "unary":
		return strings.Repeat("-", n) + "a;"
	case "at":
		return strings.Repeat("a[", n) + "0" + strings.Repeat("]", n) + ";"
	}
	panic("unknown kind " + kind)
}

func parseDepth(kind string, n int) ([]string, *stope.Prog) {
	ps := stope.NewParser(stope.NewLexer(depthSource(kind, n)), nil)
	tree := &stope.Prog{}
	ps.ParseProgram(tree)
	return ps.Errors, tree
}

func TestParserDepthLimit(t *testing.T) {
	type dc struct {
		cid  string
		kind string
		n    int
		deep bool
	}
	cases := []dc{
		{"PD-DEPTH-1", "paren", 200, false},
		{"PD-DEPTH-2", "paren", 300, true},
		{"PD-DEPTH-3", "block", 300, true},
		{"PD-DEPTH-4", "unary", 300, true},
		{"PD-DEPTH-5", "at", 300, true},
		{"PD-DEPTH-6", "paren", 12000, true},
		{"PD-DEPTH-7", "block", 200, false},
		{"PD-DEPTH-8", "unary", 200, false},
		{"PD-DEPTH-9", "at", 200, false},
	}
	rep := NewReport(t)
	for _, c := range cases {
		errors, tree := parseDepth(c.kind, c.n)
		if !c.deep {
			rep.CheckInt(c.cid+" "+c.kind, "错误条数", 0, len(errors))
			rep.CheckTrue(c.cid, "应解析出语句", len(tree.Stmts) > 0)
			continue
		}
		// 超限只报一条（不刷连锁噪音），文案逐字固定
		rep.CheckInt(c.cid+" "+c.kind, "错误条数", 1, len(errors))
		want := "line 1: nesting too deep (max 256). "
		got := "<无错误>"
		if len(errors) > 0 {
			got = errors[0]
		}
		rep.Check(c.cid, "错误文案", want, got)
	}

	ps0 := stope.NewParser(stope.NewLexer(""), nil)
	rep.CheckInt("PD-DEFAULT", "默认 max_depth", 256, ps0.MaxDepth)

	// max_depth = 0 时不检查：600 层（远超 256）仍能解析。
	ps0 = stope.NewParser(stope.NewLexer(depthSource("paren", 600)), nil)
	ps0.MaxDepth = 0
	tree0 := &stope.Prog{}
	ps0.ParseProgram(tree0)
	rep.CheckInt("PD-NOLIMIT", "错误条数", 0, len(ps0.Errors))
	rep.CheckInt("PD-NOLIMIT", "语句数", 1, len(tree0.Stmts))

	t.Logf("嵌套深度：断言 %d 条，失败 %d 条", rep.Passed, rep.Failed)
}
