package stope

import (
	"sort"
	"strconv"
	"strings"
)

// Program 反汇编（调试用）—— 端口 cpp/include/stope/debug.hpp 的 Disasm。
//
// 输出与 C++ / GDScript / Node.js / C# / Python 逐字节一致：
// 编号列宽 8、名字列宽 max(10, 最长名字)、int/float 常量同列连排、
// 字符串常量一行一个、二进制数组只印字节数、最后是 warning 段。

// 名字列的对齐宽度下限 = 内置名里最长的两个（PushString / PushBinArr，10 字节）。
const minNameWidth = 10

// padRight 按 UTF-8 字节数右填充空格（非 ASCII 名会少填几个空格，与 C++ 一致）。
func padRight(s string, width int) string {
	n := len(s)
	if n >= width {
		return s
	}
	return s + strings.Repeat(" ", width-n)
}

// OpcodeHasArg 内置指令是否带一个操作数。
// 自定义指令不走这里：它们的「带不带操作数」由 CustomOpcodeConfig 决定。
func OpcodeHasArg(op int) bool {
	if int(OpPushInt) <= op && op <= int(OpAt) {
		return true
	}
	return op == int(OpIf) || op == int(OpGoTo) || op == int(OpReturn)
}

// CustomOpcodeHasArg 自定义指令只有在变长参数时才带操作数。
func CustomOpcodeHasArg(raw int, config *CustomOpcodeConfig) bool {
	if config == nil {
		return false
	}
	for _, info := range config.Opcodes {
		if info.Opcode == raw && info.IsVarArg {
			return true
		}
	}
	return false
}

type customEntry struct {
	name string
	info CustomOpcode
}

// Disasm 把 Program 反汇编成可读文本。config 可空：产物里没有自定义指令时传 nil。
// 含自定义指令时必须传注册时用的那一份，否则名字、变长指令的参数个数都无从得知。
func Disasm(prog *Program, config *CustomOpcodeConfig) string {
	// ---------- 编号 -> (名字, 注册项) 的反查表 ----------
	customByOpcode := map[int]customEntry{}
	var warnings []string
	nameWidth := minNameWidth
	if config != nil {
		// C++ 的 CustomOpcodeConfig 是 std::map（按名字字典序）。这里显式排序，
		// 否则「谁先注册谁在前」会让自定义指令表的行序与 C++ 不一致。
		names := make([]string, 0, len(config.Opcodes))
		for name := range config.Opcodes {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			info := config.Opcodes[name]
			if info.Opcode < KFirstCustomOpcode {
				what := "(not an opcode)"
				if 0 <= info.Opcode && info.Opcode < len(OpcodeName) {
					what = OpcodeName[info.Opcode]
				}
				warnings = append(warnings,
					"custom opcode \""+name+"\" uses #"+strconv.Itoa(info.Opcode)+
						", which collides with "+what+"; builtin decoding wins.")
				continue
			}
			if prev, ok := customByOpcode[info.Opcode]; ok {
				warnings = append(warnings,
					"custom opcodes \""+prev.name+"\" and \""+name+"\" share #"+
						strconv.Itoa(info.Opcode)+"; the former wins.")
				continue
			}
			customByOpcode[info.Opcode] = customEntry{name, info}
			if w := len(name); w > nameWidth {
				nameWidth = w
			}
		}
	}

	// ---------- 指令流 ----------
	var parts []string
	var unknown []int // 不认识的编号，最后统一提示（保持首次出现顺序）
	ops := prog.Opcodes
	n := len(ops)
	i := 0
	for i < n {
		raw := ops[i]
		hasArg := false
		var name string
		if 0 <= raw && raw < len(OpcodeName) {
			name = OpcodeName[raw]
			hasArg = OpcodeHasArg(raw)
		} else {
			if it, ok := customByOpcode[raw]; ok {
				name = it.name
				hasArg = it.info.IsVarArg
			} else {
				// 编号不认识就只能印数字。绝不能猜「有没有操作数」。
				if raw > int(OpReturn) {
					name = "Custom" + strconv.Itoa(raw)
				} else {
					name = "Op#" + strconv.Itoa(raw)
				}
				seen := false
				for _, u := range unknown {
					if u == raw {
						seen = true
						break
					}
				}
				if !seen {
					unknown = append(unknown, raw)
				}
			}
		}
		parts = append(parts, padRight("["+strconv.Itoa(i)+"]", 8)+padRight(name, nameWidth)+" ")
		i++
		if hasArg {
			if i < n {
				parts = append(parts, strconv.Itoa(ops[i]))
				i++
			} else {
				parts = append(parts, "<missing operand>")
				warnings = append(warnings,
					"opcode at ["+strconv.Itoa(i-1)+"] expects an operand but the stream ends there.")
			}
		}
		parts = append(parts, "\n")
	}
	ss := strings.Join(parts, "")

	// ---------- 自定义指令表（名字、编号、参数形态一次交代清楚） ----------
	if len(customByOpcode) > 0 {
		ss += "custom opcodes:\n"
		// 必须按【编号】排序打印：C++ 的 customByOpcode 是 map<short, ...>，迭代序是编号序。
		opcodes := make([]int, 0, len(customByOpcode))
		for op := range customByOpcode {
			opcodes = append(opcodes, op)
		}
		sort.Ints(opcodes)
		for _, op := range opcodes {
			it := customByOpcode[op]
			ss += "  " + padRight(it.name, nameWidth) + " -> " + strconv.Itoa(it.info.Opcode)
			if it.info.IsVarArg {
				ss += " (vararg)"
			} else {
				ss += " (" + strconv.Itoa(it.info.ArgNum) + " args)"
			}
			ss += "\n"
		}
	}

	// ---------- 变量表与常量池 ----------
	ss += "variables:\n"
	variables := make([]string, prog.VariableNum)
	for _, e := range prog.Exports {
		if 0 <= e.Index && e.Index < len(variables) {
			variables[e.Index] = e.Name
		}
	}
	ss += "  "
	for k, v := range variables {
		ss += "\"" + v + "\""
		if k < len(variables)-1 {
			ss += " "
		}
	}
	ss += "\nint consts:\n"
	for _, v := range prog.IntConsts {
		ss += "  " + strconv.FormatInt(v, 10)
	}
	ss += "\nfloat consts:\n"
	for _, v := range prog.FloatConsts {
		ss += "  " + FmtG(v)
	}
	ss += "\nstring consts:\n"
	for _, v := range prog.StringConsts {
		ss += "  \"" + v + "\"\n"
	}
	ss += "binary array consts:\n"
	for _, v := range prog.BinarrConsts {
		ss += "  " + strconv.Itoa(len(v)) + " bytes\n"
	}
	ss += "max return num: " + strconv.Itoa(prog.MaxReturnNum) + "\n"
	ss += "required stack size: " + strconv.Itoa(prog.RequiredStackSize) + "\n"

	for _, raw := range unknown {
		if raw > int(OpReturn) {
			warnings = append(warnings,
				"opcode #"+strconv.Itoa(raw)+" is not a builtin; pass the CustomOpcodeConfig to Disasm() to decode it.")
		} else {
			warnings = append(warnings,
				"opcode #"+strconv.Itoa(raw)+" is not a valid instruction (unpatched placeholder?).")
		}
	}
	for _, w := range warnings {
		ss += "warning: " + w + "\n"
	}
	return ss
}

// DisasmNoCustom 产物里确定没有自定义指令时的简写。
func DisasmNoCustom(prog *Program) string { return Disasm(prog, nil) }
