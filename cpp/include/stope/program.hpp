#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace Stope {
struct Program {
  std::vector<short> opcodes;
  int variableNum = 0;
  std::map<std::u16string, int> exports;
  std::vector<int64_t> intConsts;
  std::vector<double> floatConsts;
  std::vector<std::vector<char>> binArrConsts;
  std::vector<std::u16string> stringConsts;
  int maxReturnNum = 0;
  int requiredStackSize = 0;
};
}  // namespace Stope
