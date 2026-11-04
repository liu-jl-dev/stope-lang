package tests

import (
	"sort"
	"strconv"
	"strings"
	"testing"

	"stope/stml"
	"stope"
)

// STML：stml_cases.txt（126 条用例清单）+ golden_stml.txt（C++ 探针 dump）。
//
// ⚠ golden_stml.txt 的字段不解转义（探针只做了 escUtf8），读进来是什么就比什么。
// 而 stml_cases.txt 的 SRC 要按 \\ \n \r \t 解一层。

func stateOf(name string) stml.LexerState {
	switch name {
	case "Text":
		return stml.TextState
	case "Nevext":
		return stml.NevextState
	case "Stope":
		return stml.StopeState
	}
	return stml.XmlState
}

// shape 元素形状串。字段顺序固定：tag、行号、自闭合、属性（字典序）、文本、子元素。
func shape(e *stml.Element) string {
	out := "Elem(" + stope.Esc(e.Tag) + ", L" + strconv.Itoa(e.Line)
	if e.SelfClosing {
		out += ", /"
	}
	names := make([]string, 0, len(e.Attrs))
	byName := map[string]string{}
	for _, a := range e.Attrs {
		names = append(names, a.Name)
		byName[a.Name] = a.Value
	}
	sort.Strings(names)
	for _, name := range names {
		out += ", @" + stope.Esc(name)
		if byName[name] != "" {
			out += "=\"" + stope.Esc(byName[name]) + "\""
		}
	}
	if e.Text != "" {
		out += ", T(L" + strconv.Itoa(e.TextLine) + ")=\"" + stope.Esc(e.Text) + "\""
	}
	if len(e.Children) > 0 {
		out += ", C=["
		for i, c := range e.Children {
			if i > 0 {
				out += " "
			}
			out += shape(c)
		}
		out += "]"
	}
	return out + ")"
}

func runStmlLex(rep *Report, cid string, want map[string]string, src string, startState stml.LexerState) {
	lx := stml.NewLexer(src, startState)
	var toks, lexs []string
	for i := 0; i < 10000; i++ { // 死循环保险丝
		tok := lx.NextToken()
		toks = append(toks, stml.TypeName(tok.Type)+"("+strconv.Itoa(tok.Line)+")")
		if stml.HasLexeme(tok.Type) {
			lexs = append(lexs, strconv.Itoa(i)+":"+stope.Esc(tok.Lexeme))
		}
		if tok.Type == stml.TEof {
			break
		}
	}
	rep.Check(cid, "TOKS", want["TOKS"], strings.Join(toks, " "))
	rep.Check(cid, "LEXS", want["LEXS"], strings.Join(lexs, ","))
	rep.Check(cid, "ERRN", want["ERRN"], strconv.Itoa(len(lx.Errors)))
	rep.Check(cid, "ERRS", want["ERRS"], joinEsc16(lx.Errors))
}

func runStmlParse(rep *Report, cid string, want map[string]string, src string, maxDepth int, sfKind string) {
	lx := stml.NewLexer(src, stml.XmlState)
	ps := stml.NewParser(lx)
	ps.MaxDepth = maxDepth
	root := stml.NewElement()
	var stateFunc stml.StateFunc
	switch sfKind {
	case "null":
		stateFunc = nil
	case "text":
		stateFunc = func(_ string, _ map[string]string) stml.LexerState { return stml.TextState }
	default:
		stateFunc = stml.DefaultStateFunc
	}

	rc := ps.Parse(root, stateFunc)
	rep.Check(cid, "SHAPE", want["SHAPE"], shape(root))
	result := "Error"
	if rc == stml.Success {
		result = "Success"
	}
	rep.Check(cid, "RESULT", want["RESULT"], result)
	rep.Check(cid, "ERRN", want["ERRN"], strconv.Itoa(len(ps.Errors)))
	rep.Check(cid, "ERRS", want["ERRS"], joinEsc16(ps.Errors))
	rep.Check(cid, "LEXERRN", want["LEXERRN"], strconv.Itoa(len(lx.Errors)))
	rep.Check(cid, "LEXERRS", want["LEXERRS"], joinEsc16(lx.Errors))
}

func TestGoldenStml(t *testing.T) {
	cases := readStmlCases(t)
	if len(cases) == 0 {
		t.Fatal("stml_cases.txt 一条都没读到")
	}
	want := map[string]map[string]string{}
	for _, r := range readGolden(t, "golden_stml.txt", false) {
		want[r["ID"]] = r
	}
	if len(want) != 126 {
		t.Errorf("golden_stml.txt 条数 = %d, want 126", len(want))
	}

	rep := NewReport(t)
	seenLex, seenParse := 0, 0
	for _, c := range cases {
		cid := c["ID"]
		rec, ok := want[cid]
		if !ok {
			rep.Fail(cid, "golden_stml.txt 里没有这条")
			continue
		}
		times, _ := strconv.Atoi(c["times"])
		if times == 0 {
			times = 1
		}
		src := strings.Repeat(c["src"], times)
		if c["KIND"] == "parse" {
			seenParse++
			md := 256
			if s := c["MD"]; s != "" {
				md, _ = strconv.Atoi(s)
			}
			runStmlParse(rep, cid, rec, src, md, c["SF"])
		} else {
			seenLex++
			runStmlLex(rep, cid, rec, src, stateOf(c["ST"]))
		}
	}

	// 清单与期望值必须一一对应（少一条就是「用例没跑」而不是「用例通过」）
	rep.CheckInt("COUNT", "清单 ↔ golden 条数", len(cases), len(want))
	rep.CheckInt("COUNT", "词法 + 语法", len(cases), seenLex+seenParse)

	t.Logf("STML：stml_cases.txt %d 条，断言 %d 条，失败 %d 条", len(cases), rep.Passed, rep.Failed)
}
