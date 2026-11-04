// golden 数据的读取、转义与断言计数。数据真源在 gdscript/test/data/（只读，
// 绝不复制进 go/）。转义约定每个文件都不一样：
//
//	golden.txt       值解一层，SRC 解两层
//	golden_disasm    值解一层，SRC 解两层
//	golden_lex.txt   不解，SRC 用 unescapeLex（多认 \v \f）
//	golden_stml.txt  不解，SRC 用 unescapeLex
//	stml_cases.txt   SRC 用 unescapeLex
package tests

import (
	"os"
	"strconv"
	"strings"
	"testing"

	"stope"
)

// dataDir golden 数据目录（绝对路径，Windows 写法）。
const dataDir = "E:/lib/stope-lang/gdscript/test/data"

func dataPath(name string) string { return dataDir + "/" + name }

// readText 读一份数据文件，统一剥掉 \r。
func readText(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(dataPath(name))
	if err != nil {
		t.Fatalf("读不到 golden 数据 %s: %v", dataPath(name), err)
	}
	return strings.ReplaceAll(string(b), "\r", "")
}

// unescape 反转义：与探针的 E_() 对称（\\ \n \r \t，其余原样保留）。
func unescape(s string) string {
	var b strings.Builder
	i, n := 0, len(s)
	for i < n {
		ch := s[i]
		if ch != '\\' {
			b.WriteByte(ch)
			i++
			continue
		}
		i++
		var c byte
		if i < n {
			c = s[i]
		}
		i++
		switch c {
		case '\\':
			b.WriteByte('\\')
		case 'n':
			b.WriteByte('\n')
		case 'r':
			b.WriteByte('\r')
		case 't':
			b.WriteByte('\t')
		default:
			b.WriteByte('\\')
			b.WriteByte(c)
		}
	}
	return b.String()
}

// unescapeLex 与 unescape 相同，但多认 \v 与 \f —— 词法与 STML 的 SRC 用这套。
func unescapeLex(s string) string {
	var b strings.Builder
	i, n := 0, len(s)
	for i < n {
		if s[i] == '\\' && i+1 < n {
			switch s[i+1] {
			case '\\':
				b.WriteByte('\\')
				i += 2
				continue
			case 'n':
				b.WriteByte('\n')
				i += 2
				continue
			case 'r':
				b.WriteByte('\r')
				i += 2
				continue
			case 't':
				b.WriteByte('\t')
				i += 2
				continue
			case 'v':
				b.WriteByte('\v')
				i += 2
				continue
			case 'f':
				b.WriteByte('\f')
				i += 2
				continue
			}
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}

// joinEsc errs 用 esc_lex 形态连接（golden.txt / golden_lex.txt / golden_disasm.txt）。
func joinEsc(errs []string) string {
	out := make([]string, len(errs))
	for i, e := range errs {
		out[i] = stope.EscLex(e)
	}
	return strings.Join(out, "|")
}

// joinEsc16 errs 用 escUtf8（UTF-16 码元）形态连接（golden_stml.txt 的 ERRS）。
func joinEsc16(errs []string) string {
	out := make([]string, len(errs))
	for i, e := range errs {
		out[i] = stope.Esc(e)
	}
	return strings.Join(out, "|")
}

// readGolden 读一份 golden 文件 → 若干 KEY=VALUE 字典，行首 # 是注释。
// unescapeValues：golden.txt 与 golden_disasm.txt 的字段经过探针的 E_() 二次转义，
// 读进来要解一层；golden_stml.txt 只做了 escUtf8，多解一层会把 \n 变成真换行。
func readGolden(t *testing.T, name string, unescapeValues bool) []map[string]string {
	t.Helper()
	text := readText(t, name)
	var out []map[string]string
	for _, line := range strings.Split(text, "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		rec := map[string]string{}
		for _, field := range strings.Split(line, "\t") {
			eq := strings.IndexByte(field, '=')
			if eq < 0 {
				continue
			}
			v := field[eq+1:]
			if unescapeValues {
				v = unescape(v)
			}
			rec[field[:eq]] = v
		}
		if len(rec) > 0 {
			out = append(out, rec)
		}
	}
	return out
}

// readBinarrGolden golden_binarr.txt 有两类记录，按 TAB 位置切。
func readBinarrGolden(t *testing.T) []map[string]string {
	t.Helper()
	var out []map[string]string
	for _, line := range strings.Split(readText(t, "golden_binarr.txt"), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		head := line[:3]
		if head == "BA\t" {
			parts := strings.Split(line[3:], "\t")
			status := parts[len(parts)-2]
			content := strings.Join(parts[:len(parts)-2], "\t")
			out = append(out, map[string]string{
				"kind": "BA", "content": content,
				"ok": status, "bytes": parts[len(parts)-1],
			})
		} else if head == "FB\t" || head == "FU\t" {
			parts := strings.Split(line, "\t")
			kind := "FB"
			if head == "FU\t" {
				kind = "FU"
			}
			out = append(out, map[string]string{
				"kind": kind, "op": parts[1], "left": parts[2], "result": parts[3],
			})
		}
	}
	return out
}

// readStmlCases stml_cases.txt：STML 的用例清单（四方共用）。
func readStmlCases(t *testing.T) []map[string]string {
	t.Helper()
	var out []map[string]string
	for _, line := range strings.Split(readText(t, "stml_cases.txt"), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		rec := map[string]string{}
		for _, part := range strings.Split(line, "\t") {
			eq := strings.IndexByte(part, '=')
			if eq < 0 {
				continue
			}
			rec[part[:eq]] = part[eq+1:]
		}
		if _, ok := rec["ID"]; !ok {
			continue
		}
		rec["src"] = unescapeLex(rec["SRC"])
		rec["times"] = rec["TIMES"]
		if rec["times"] == "" {
			rec["times"] = "1"
		}
		out = append(out, rec)
	}
	return out
}

func itoa(n int) string { return strconv.Itoa(n) }

// ---------------- 断言计数 ----------------

// Report 断言计数器：失败即 t.Errorf（记录用例与字段），通过即计数。
type Report struct {
	t      *testing.T
	Passed int
	Failed int
}

// NewReport 构造。
func NewReport(t *testing.T) *Report { return &Report{t: t} }

// Check 比较字符串字段。
func (r *Report) Check(cid, field, want, got string) {
	r.Passed++
	if want != got {
		r.Failed++
		r.t.Errorf("[%s] %s 不一致\n  want: %q\n  got:  %q", cid, field, want, got)
	}
}

// CheckInt 比较整数字段（want 与 got 都按十进制串比，golden 期望值是字符串）。
func (r *Report) CheckInt(cid, field string, want, got int) {
	r.Check(cid, field, strconv.Itoa(want), strconv.Itoa(got))
}

// CheckStrInt 期望值是串、实际值是 int。
func (r *Report) CheckStrInt(cid, field, want string, got int) {
	r.Check(cid, field, want, strconv.Itoa(got))
}

// CheckTrue 布尔断言。
func (r *Report) CheckTrue(cid, desc string, ok bool) {
	r.Passed++
	if !ok {
		r.Failed++
		r.t.Errorf("[%s] %s: 应为真", cid, desc)
	}
}

// Fail 直接记一条失败。
func (r *Report) Fail(cid, msg string) {
	r.Passed++
	r.Failed++
	r.t.Errorf("[%s] %s", cid, msg)
}
