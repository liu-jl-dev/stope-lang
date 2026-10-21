#pragma once
#include <map>
#include <string>
#include <stope/common.hpp>
#include <stope/opcode.hpp>

namespace Stope {
struct CustomOpcode {
  short opcode;
  bool isVarArg;  // 变长参数指令的编译结果多一个 int16。加一个标志位比较方便。
  short argNum;
};
struct CustomOpcodeConfig {
  std::map<std::u16string, CustomOpcode> opcodes;
  Result addCustomOpcode(std::u16string& name, short opcode,
                       short argNum = -1) {  // -1 表示变长参数
    if (opcodes.find(name) != opcodes.end()){
      return Result::DuplicateWithBuiltinOpcode;
    }
    bool isVarArg = argNum < 0;
    opcodes.emplace(name, CustomOpcode{opcode, isVarArg, argNum});
    return Result::Success;
  }
};
}  // namespace Stope
