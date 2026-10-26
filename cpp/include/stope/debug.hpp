#pragma once
// Program 反汇编（调试用）。
//
// 内置 32 条指令的名字与「是否带操作数」在 opcode.hpp 里是固定的；自定义指令
// （编号 > Opcode::Return）的名字、参数个数只有 CustomOpcodeConfig 知道。所以
// 产物里只要可能有自定义指令，就得用 DumpProgram(program, &config) 打印：
//   * 不带 config 只能用 Custom\#编号 占位，而且变长指令后面那个「参数个数」会被
//     当成下一条指令（两者只差一个 short，读起来会全错位）；
//   * 带 config 才会印出名字，并按 isVarArg 决定要不要吃掉后面那个 short。
#include <cstddef>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include <stope/opcode.hpp>
#include <stope/program.hpp>
#include <stope/utf.hpp>

namespace Stope {

// 自定义指令的编号必须大于 Opcode::Return（compiler_test_plan.md §4.4）：
// opcodes 是 short 混排序列，撞号以后编译器写出的仍是同一个 short，运行时与
// 反汇编都看不出区别。DumpProgram 会把这种注册报成 warning。
inline constexpr short kFirstCustomOpcode =
    static_cast<short>(Opcode::Return) + 1;

namespace Debug {

// 下标与内置名一一对应，顺序必须跟 Opcode 枚举一致（opcode.hpp）。
// 这张表按行手工对齐是为了让「第几个」看得清，别让格式化器揉成一团。
// clang-format off
inline constexpr const char* kBuiltinOpcodeNames[] = {
    "Assign",    "PushNull",   "PushFalse",  "PushTrue",   "PushInt",
    "PushFloat", "PushString", "PushBinArr", "PushValue",  "PushId",
    "Call",      "At",         "Pop",        "Minus",      "Not",
    "Pow",       "Mul",        "Div",        "IDiv",       "Mod",
    "Add",       "Sub",        "EQ",         "NE",         "LT",
    "LE",        "GT",         "GE",         "If",         "GoTo",
    "GetArg",    "ArgNum",     "Return",
};
// clang-format on
inline constexpr int kBuiltinOpcodeCount = static_cast<int>(
    sizeof(kBuiltinOpcodeNames) / sizeof(kBuiltinOpcodeNames[0]));

// 名字列的对齐宽度下限 = 内置名里最长的两个（PushString / PushBinArr，10 字节）。
// 自定义名更长时整列变宽。名字按 UTF-8 字节数丈量，非 ASCII 名会把列撑宽一点，
// 但不会串行。
inline constexpr std::size_t kMinOpcodeNameWidth = 10;

inline std::string padRight(const std::string& s, std::size_t width) {
  std::string out = s;
  while (out.size() < width)
    out += ' ';
  return out;
}

}  // namespace Debug

// 内置指令是否带一个操作数（操作数占紧随其后的一个 short）。
// 自定义指令不走这里：它们的「带不带操作数」由 CustomOpcodeConfig 决定。
inline bool OpcodeHasArg(Opcode op) {
  if (op >= Opcode::PushInt && op <= Opcode::At) {
    return true;
  }
  if (op == Opcode::If || op == Opcode::GoTo || op == Opcode::Return) {
    return true;
  }
  return false;
}

// 自定义指令只有在变长参数时才带操作数 —— 那个操作数是本次调用的参数个数
// （定长指令的参数个数是注册时定死的，编译产物里不再重复写）。
inline bool CustomOpcodeHasArg(short raw, const CustomOpcodeConfig& config) {
  for (const auto& kv : config.opcodes) {
    if (kv.second.opcode == raw && kv.second.isVarArg)
      return true;
  }
  return false;
}

// 把 Program 反汇编成可读文本。
//
// config 可空：产物里没有自定义指令时传 nullptr 即可（就是原来的
// DumpProgramNoCustom）。含自定义指令时**必须**传注册时用的那一份，否则名字、
// 变长指令的参数个数都无从得知。
inline std::string DumpProgram(const Program& prog,
                               const CustomOpcodeConfig* config = nullptr) {
  using namespace std;

  // ---------- 编号 -> (名字, 注册项) 的反查表 ----------
  map<short, pair<u16string, const CustomOpcode*>> customByOpcode;
  vector<string> warnings;
  size_t nameWidth = Debug::kMinOpcodeNameWidth;
  if (config != nullptr) {
    for (const auto& kv : config->opcodes) {  // std::map：按名字字典序
      const string name = UTF::Utf16ToUtf8(kv.first);
      const CustomOpcode& info = kv.second;
      if (info.opcode < kFirstCustomOpcode) {
        const string what =
            (info.opcode >= 0 && info.opcode < Debug::kBuiltinOpcodeCount)
                ? Debug::kBuiltinOpcodeNames[info.opcode]
                : "(not an opcode)";
        warnings.push_back("custom opcode \"" + name + "\" uses #" +
                           to_string(info.opcode) + ", which collides with " +
                           what + "; builtin decoding wins.");
        continue;
      }
      auto it = customByOpcode.find(info.opcode);
      if (it != customByOpcode.end()) {
        warnings.push_back("custom opcodes \"" +
                           UTF::Utf16ToUtf8(it->second.first) + "\" and \"" +
                           name + "\" share #" + to_string(info.opcode) +
                           "; the former wins.");
        continue;
      }
      customByOpcode.emplace(info.opcode, make_pair(kv.first, &info));
      nameWidth = max(nameWidth, name.size());
    }
  }

  // ---------- 指令流 ----------
  stringstream ss;
  set<short> unknown;  // 不认识的编号，最后统一提示
  const int n = static_cast<int>(prog.opcodes.size());
  for (int i = 0; i < n; ++i) {
    const short raw = prog.opcodes[i];
    string name;
    bool hasArg = false;
    if (raw >= 0 && raw < Debug::kBuiltinOpcodeCount) {
      name = Debug::kBuiltinOpcodeNames[raw];
      hasArg = OpcodeHasArg(static_cast<Opcode>(raw));
    } else {
      auto it = customByOpcode.find(raw);
      if (it != customByOpcode.end()) {
        name = UTF::Utf16ToUtf8(it->second.first);
        hasArg = it->second.second->isVarArg;
      } else {
        // 编号不认识就只能印数字。绝不能猜「有没有操作数」，否则会把下一条
        // 指令当成操作数吃掉、后面整段错位。
        name = raw > static_cast<short>(Opcode::Return)
                   ? "Custom" + to_string(raw)
                   : "Op#" + to_string(raw);
        unknown.insert(raw);
      }
    }
    ss << Debug::padRight("[" + to_string(i) + "]", 8)
       << Debug::padRight(name, nameWidth) << " ";
    if (hasArg) {
      if (i + 1 < n) {
        ss << prog.opcodes[++i];
      } else {
        ss << "<missing operand>";
        warnings.push_back("opcode at [" + to_string(i) +
                           "] expects an operand but the stream ends there.");
      }
    }
    ss << "\n";
  }

  // ---------- 自定义指令表（名字、编号、参数形态一次交代清楚） ----------
  if (!customByOpcode.empty()) {
    ss << "custom opcodes:\n";
    for (const auto& kv : customByOpcode) {
      const CustomOpcode& info = *kv.second.second;
      ss << "  "
         << Debug::padRight(UTF::Utf16ToUtf8(kv.second.first), nameWidth)
         << " -> " << info.opcode;
      if (info.isVarArg)
        ss << " (vararg)";
      else
        ss << " (" << info.argNum << " args)";
      ss << "\n";
    }
  }

  // ---------- 变量表与常量池 ----------
  ss << "variables:\n";
  vector<string> vars(prog.variableNum);
  for (auto& kv : prog.exports) {
    vars[kv.second] = UTF::Utf16ToUtf8(kv.first);
  }
  ss << "  ";
  for (int i = 0; i < static_cast<int>(vars.size()); ++i) {
    ss << '"' << vars[i] << '"';
    if (i < static_cast<int>(vars.size()) - 1) {
      ss << " ";
    }
  }
  ss << "\nint consts:\n";
  for (auto& v : prog.intConsts) {
    ss << "  " << v;
  }
  ss << "\nfloat consts:\n";
  for (auto& v : prog.floatConsts) {
    ss << "  " << v;
  }
  ss << "\nstring consts:\n";
  for (auto& v : prog.stringConsts) {
    ss << "  \"" << UTF::Utf16ToUtf8(v) << "\"\n";
  }
  ss << "binary array consts:\n";
  for (auto& v : prog.binArrConsts) {
    ss << "  " << v.size() << " bytes\n";
  }
  ss << "max return num: " << prog.maxReturnNum << "\n";
  ss << "required stack size: " << prog.requiredStackSize << "\n";

  for (short raw : unknown) {
    if (raw > static_cast<short>(Opcode::Return))
      warnings.push_back("opcode #" + to_string(raw) +
                         " is not a builtin; pass the CustomOpcodeConfig to "
                         "DumpProgram() to decode it.");
    else
      warnings.push_back(
          "opcode #" + to_string(raw) +
          " is not a valid instruction (unpatched placeholder?).");
  }
  for (const auto& w : warnings) {
    ss << "warning: " << w << "\n";
  }
  return ss.str();
}

// 产物里确定没有自定义指令时的简写。
inline std::string DumpProgramNoCustom(const Program& prog) {
  return DumpProgram(prog, nullptr);
}

}  // namespace Stope
