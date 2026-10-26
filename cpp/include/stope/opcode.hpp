#pragma once
#include <stope/common.hpp>
#include <map>
#include <string>

namespace Stope {
enum class Opcode : unsigned short {
  Assign,      // 0
  PushNull,    // 1
  PushFalse,   // 2
  PushTrue,    // 3
  PushInt,     // 4
  PushFloat,   // 5
  PushString,  // 6
  PushBinArr,  // 7
  PushValue,   // 8
  PushId,      // 9

  Call,   // 10
  At,     // 11
  Pop,    // 12
  Minus,  // 13
  Not,    // 14
  Pow,    // 15
  Mul,    // 16
  Div,    // 17
  IDiv,   // 18
  Mod,    // 19

  Add,   // 20
  Sub,   // 21
  EQ,    // 22
  NE,    // 23
  LT,    // 24
  LE,    // 25
  GT,    // 26
  GE,    // 27
  If,    // 28
  GoTo,  // 29

  GetArg,  // 30
  ArgNum,  // 31
  Return,  // 32
};  // 共 33 个

struct CustomOpcode {
  short opcode;
  bool isVarArg;  // 变长参数指令的编译结果多一个 int16。加一个标志位比较方便。
  short argNum;
};
struct CustomOpcodeConfig {
  std::map<std::u16string, CustomOpcode> opcodes;
  Result addCustomOpcode(std::u16string& name,
                         short opcode,
                         short argNum = -1) {  // -1 表示变长参数
    if (opcodes.find(name) != opcodes.end()) {
      return Result::DuplicateWithBuiltinOpcode;
    }
    bool isVarArg = argNum < 0;
    opcodes.emplace(name, CustomOpcode{opcode, isVarArg, argNum});
    return Result::Success;
  }
};

}  // namespace Stope
