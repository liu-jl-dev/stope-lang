package tests

import (
	"testing"

	"stope"
)

// 编译器：golden.txt 的 CMP / OUT / CERRS 三个字段（224 条）。

func TestGoldenCompiler(t *testing.T) {
	cases := readGoldenMain(t)
	rep := NewReport(t)
	for _, rec := range cases {
		cid := rec["ID"]
		got := runParserCase(rec)
		// PRE：预导出名单，逗号分隔（空元素表示一个空名字）；字段为空 = 不预导出
		pre := rec["PRE"]
		var preExports []string
		if pre != "" {
			preExports = splitCSV(pre)
		}
		prog := stope.NewProgram()
		c := stope.NewCompiler(CFG)
		rc := c.Compile(got.Tree, prog, preExports)
		cmp := "OK"
		if rc != stope.RSuccess {
			cmp = "ERR"
		}
		rep.Check(cid, "CMP", rec["CMP"], cmp)
		rep.Check(cid, "OUT", rec["OUT"], stope.DumpProgram(prog, CFG))
		rep.Check(cid, "CERRS", rec["CERRS"], joinEsc(c.Errors))
	}
	t.Logf("编译器：golden.txt %d 条，断言 %d 条，失败 %d 条", len(cases), rep.Passed, rep.Failed)
}

// splitCSV 逗号分隔（Python 的 pre.split(",")：保留空元素）。
func splitCSV(s string) []string {
	out := []string{}
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == ',' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}
