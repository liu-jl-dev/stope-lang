package tests

import (
	"strconv"
	"strings"
	"testing"

	"stope"
)

// 词法：全部由 golden_lex.txt（147 条，C++ 探针 dump）驱动。
// 每条用例断言四件事：TOKS / LEXEMES / ERRN / ERRS。
//
// ⚠ 这个文件的 TOKS / LEXEMES / ERRS 不做二次转义：直接就是 esc_lex 形态，
// 只有 SRC 是转义过的（且转义表里多 \v \f）。

func lexOne(src string) (toks, lexemes string, errn int, errs string) {
	lx := stope.NewLexer(src)
	var t, l []string
	for i := 0; i < 10000; i++ {
		tok := lx.NextToken(CFG)
		s := stope.TypeName(tok.Type) + "(" + strconv.Itoa(tok.Line) + ")"
		if tok.Parsed != "" {
			s += "[" + stope.EscLex(tok.Parsed) + "]"
		}
		if tok.Type == stope.TInteger {
			s += "=" + strconv.FormatInt(tok.IVal, 10)
		} else if tok.Type == stope.TFloat {
			s += "=" + stope.FmtG(tok.FVal)
		}
		t = append(t, s)
		switch tok.Type {
		case stope.TInteger, stope.TFloat, stope.TString, stope.TBinArr:
			l = append(l, strconv.Itoa(i)+":"+stope.EscLex(tok.Lexeme))
		}
		if tok.Type == stope.TEof {
			break
		}
	}
	return strings.Join(t, " "), strings.Join(l, ","), len(lx.Errors), joinEsc(lx.Errors)
}

func TestGoldenLexer(t *testing.T) {
	cases := readGolden(t, "golden_lex.txt", false)
	if len(cases) == 0 {
		t.Fatal("golden_lex.txt 一条都没读到")
	}
	if len(cases) != 147 {
		t.Errorf("golden_lex.txt 条数 = %d, want 147", len(cases))
	}
	rep := NewReport(t)
	rep.CheckInt("golden_lex.txt", "用例数", 147, len(cases))
	for _, c := range cases {
		cid := c["ID"]
		src := unescapeLex(c["SRC"])
		toks, lexemes, errn, errs := lexOne(src)
		rep.Check(cid, "TOKS", c["TOKS"], toks)
		rep.Check(cid, "LEXEMES", c["LEXEMES"], lexemes)
		rep.Check(cid, "ERRN", c["ERRN"], strconv.Itoa(errn))
		rep.Check(cid, "ERRS", c["ERRS"], errs)
	}
	t.Logf("词法：golden_lex.txt %d 条，断言 %d 条，失败 %d 条", len(cases), rep.Passed, rep.Failed)
}
