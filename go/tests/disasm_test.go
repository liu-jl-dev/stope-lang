package tests

import (
	"strconv"
	"strings"
	"testing"

	"stope"
)

// 反汇编：golden_disasm.txt（12 条，cpp/tools/golden_disasm.cpp dump）。
// 逐字节比 Disasm 的完整输出（含 variables: / 常量池 / warning 段）。

// 与探针里的 g_cfg 一致：myop #100（2 个参数）/ vop #101（变长）
var mainDisasmCfg = func() *stope.CustomOpcodeConfig {
	c := stope.NewCustomOpcodeConfig()
	c.AddCustomOpcode("myop", 100, 2)
	c.AddCustomOpcode("vop", 101, -1)
	return c
}()

// 故意撞内置 Add
var collideCfg = func() *stope.CustomOpcodeConfig {
	c := stope.NewCustomOpcodeConfig()
	c.AddCustomOpcode("my:steal", int(stope.OpAdd), 2)
	return c
}()

func TestGoldenDisasm(t *testing.T) {
	cases := readGolden(t, "golden_disasm.txt", true)
	if len(cases) == 0 {
		t.Fatal("golden_disasm.txt 一条都没读到")
	}
	if len(cases) != 12 {
		t.Errorf("golden_disasm.txt 条数 = %d, want 12", len(cases))
	}
	rep := NewReport(t)
	rep.CheckInt("golden_disasm.txt", "用例数", 12, len(cases))

	for _, rec := range cases {
		cid := rec["ID"]
		var cfg *stope.CustomOpcodeConfig
		switch rec["CFG"] {
		case "main":
			cfg = mainDisasmCfg
		case "collide":
			cfg = collideCfg
		}

		var prog *stope.Program
		var got string
		if rec["MODE"] == "src" {
			// SRC 是 E_(escUtf8(源码))，要解两层
			src := unescape(rec["SRC"])
			tree := &stope.Prog{}
			stope.NewParser(stope.NewLexer(src), cfg).ParseProgram(tree)
			prog = stope.NewProgram()
			stope.NewCompiler(cfg).Compile(tree, prog, nil)
			got = stope.Disasm(prog, cfg)
		} else {
			// raw：直接给指令流，不经过前端
			prog = stope.NewProgram()
			for _, s := range strings.Split(rec["OPS"], ",") {
				if s != "" {
					v, _ := strconvAtoi(s)
					prog.Opcodes = append(prog.Opcodes, v)
				}
			}
			if s := rec["VARS"]; s != "" {
				v, _ := strconvAtoi(s)
				prog.VariableNum = v
			}
			got = stope.Disasm(prog, cfg)
		}
		rep.Check(cid, "DIS", rec["DIS"], got)
	}

	// ---- 单测：这四条锁的是「golden 恰好看不出差别」的细节 ----
	rep.CheckTrue("DISP-NOCUSTOM", "DisasmNoCustom 等价于 Disasm(prog, nil)",
		stope.DisasmNoCustom(stope.NewProgram()) == stope.Disasm(stope.NewProgram(), nil))

	// OpcodeHasArg 的分档：PushInt..At 与 If/GoTo/Return 带操作数
	wantArg := map[int]bool{}
	for op := int(stope.OpPushInt); op <= int(stope.OpAt); op++ {
		wantArg[op] = true
	}
	wantArg[int(stope.OpIf)] = true
	wantArg[int(stope.OpGoTo)] = true
	wantArg[int(stope.OpReturn)] = true
	var bad []int
	for op := 0; op < 33; op++ {
		if stope.OpcodeHasArg(op) != wantArg[op] {
			bad = append(bad, op)
		}
	}
	rep.CheckTrue("DISP-ARG", "opcode_has_arg 的分档", len(bad) == 0)

	// 只有变长自定义指令才带操作数
	rep.CheckTrue("DISP-CUSTOM-ARG", "定长指令不带操作数", !customHasArg(100))
	rep.CheckTrue("DISP-CUSTOM-ARG", "变长指令带操作数", customHasArg(101))

	// custom opcodes 段按【编号】排序，不是名字序
	cfg := stope.NewCustomOpcodeConfig()
	cfg.AddCustomOpcode("a_first", 101, -1) // 名字序在前，编号在后
	cfg.AddCustomOpcode("b_second", 100, 2) // 名字序在后，编号在前
	prog := stope.NewProgram()
	prog.Opcodes = append(prog.Opcodes, 101, 0, 100, 3)
	text := stope.Disasm(prog, cfg)
	table := text[strings.Index(text, "custom opcodes:"):]
	rep.CheckTrue("DISP-SORT", "custom opcodes 段按编号排序（100 在 101 之前）",
		strings.Index(table, "b_second") < strings.Index(table, "a_first"))

	t.Logf("反汇编：golden_disasm.txt %d 条 + 4 组单测，断言 %d 条，失败 %d 条",
		len(cases), rep.Passed, rep.Failed)
}

func customHasArg(opcode int) bool {
	cfg := stope.NewCustomOpcodeConfig()
	argNum := 2
	if opcode == 101 {
		argNum = -1
	}
	cfg.AddCustomOpcode("x", opcode, argNum)
	return stope.CustomOpcodeHasArg(opcode, cfg)
}

func strconvAtoi(s string) (int, error) { return strconv.Atoi(s) }
