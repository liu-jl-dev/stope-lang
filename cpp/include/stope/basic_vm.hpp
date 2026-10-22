#pragma once
//
// basic_vm.hpp —— 执行 Program 的栈式虚拟机（header-only，C++20）
//
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <string>
#include <vector>

#include <stope/common.hpp>
#include <stope/opcode.hpp>
#include <stope/program.hpp>

namespace Stope::BasicVM {

struct Allocator {
  struct BinArrData {
    bool isDeleted = false;
    int refCount = 0;
    std::vector<char> data;
  };
  struct StringData {
    bool isDeleted = false;
    int refCount = 0;
    std::u16string data;
  };
  std::vector<BinArrData> binArrs;
  std::vector<StringData> strings;
  std::vector<unsigned> recycledBinArrs;
  std::vector<unsigned> recycledStrings;
  Allocator() = default;
  Allocator(const Allocator&) = delete;
  Allocator& operator=(const Allocator&) = delete;
  [[nodiscard]] unsigned NewBinArr() {
    unsigned handle;
    if (!recycledBinArrs.empty()) {
      std::pop_heap(recycledBinArrs.begin(), recycledBinArrs.end(),
                    std::greater<unsigned>());
      handle = recycledBinArrs.back();
      recycledBinArrs.pop_back();
    } else {
      handle = binArrs.size();
      binArrs.push_back({});
    }
    binArrs[handle].refCount = 1;
    return handle;
  }
  void BinArrRefInc(unsigned handle) {
    if (handle < binArrs.size()) {
      binArrs[handle].refCount++;
    }
  }
  void BinArrRefDec(unsigned handle) {
    if (handle >= binArrs.size()) {
      return;
    }
    binArrs[handle].refCount--;
    if (binArrs[handle].refCount <= 0) {
      deleteBinArr(handle);
    }
  }

  [[nodiscard]] unsigned NewString() {
    unsigned handle;
    if (!recycledStrings.empty()) {
      std::pop_heap(recycledStrings.begin(), recycledStrings.end(),
                    std::greater<unsigned>());
      handle = recycledStrings.back();
      recycledStrings.pop_back();
    } else {
      handle = strings.size();
      strings.push_back({});
    }
    strings[handle].refCount = 1;
    return handle;
  }
  void StringRefInc(unsigned handle) {
    if (handle < strings.size()) {
      strings[handle].refCount++;
    }
  }
  void StringRefDec(unsigned handle) {
    if (handle >= strings.size() || strings[handle].isDeleted) {
      return;
    }
    strings[handle].refCount--;
    if (strings[handle].refCount <= 0) {
      deleteString(handle);
    }
  }
  std::vector<char>& GetBinArr(unsigned handle) { return binArrs[handle].data; }
  std::u16string& GetString(unsigned handle) { return strings[handle].data; }

 private:
  void deleteBinArr(unsigned handle) {
    binArrs[handle].isDeleted = true;
    binArrs[handle].data.clear();
    recycledBinArrs.push_back(handle);
    std::push_heap(recycledBinArrs.begin(), recycledBinArrs.end(),
                   std::greater<unsigned>());
  }
  void deleteString(unsigned handle) {
    strings[handle].isDeleted = true;
    strings[handle].data.clear();
    recycledStrings.push_back(handle);
    std::push_heap(recycledStrings.begin(), recycledStrings.end(),
                   std::greater<unsigned>());
  }
};

struct Value;
struct State;
using HostFunction = void (*)(State& state,
                              std::span<const Value> args,
                              Value& output);

struct Value {
  enum class Type {
    Null,
    Integer,
    Float,
    BinArr,
    String,
    Identifier,
    HostFunction,
  };
  union Data {
    int64_t data;
    int64_t integer;
    double floating;
    unsigned index;
    unsigned handle;
    HostFunction hostFuncPtr;
  };
  Type type = Type::Null;
  Data data = {};
  Value() = default;
  Value(const Value&) = delete;
  Value& operator=(const Value&) = delete;
  // 移动 = 位拷贝 + 把源置空（句柄所有权转移，refCount 不变）。
  // 不触碰 *this 原有的句柄：调用方必须保证被覆盖的旧值已被 Clear2。
  Value(Value&& other) noexcept : type(other.type), data(other.data) {
    other.type = Type::Null;
    other.data = {};
  }
  Value& operator=(Value&& other) noexcept {
    if (this != &other) {
      type = other.type;
      data = other.data;
      other.type = Type::Null;
      other.data = {};
    }
    return *this;
  }
  void Clear(Allocator& alloc) {
    if (type == Type::BinArr) {
      alloc.BinArrRefDec(data.handle);
    } else if (type == Type::String) {
      alloc.StringRefDec(data.handle);
    }
    data.data = 0;
    type = Type::Null;
  }
  void Clear2(Allocator& alloc) {
    if (type == Type::BinArr) {
      alloc.BinArrRefDec(data.handle);
    } else if (type == Type::String) {
      alloc.StringRefDec(data.handle);
    }
  }
  static void Copy(Allocator& alloc, Value& src, Value& dst) {
    dst.type = src.type;
    if (src.type == Type::BinArr) {
      alloc.BinArrRefInc(src.data.handle);
    } else if (src.type == Type::String) {
      alloc.StringRefInc(src.data.handle);
    }
    dst.data.data = src.data.data;
  }
  // 所有权转移：dst 接走 src 的句柄，src 变 Null 但**不能 RefDec**。
  // 引用计数的含义是「几个 Value 持有它」，转移后持有者数量不变。
  // 若这里调 src.Clear，计数会比实际持有者少 1，迟早提前释放。
  static void Move(Allocator& alloc, Value& src, Value& dst) {
    if (dst.type == Type::BinArr) {
      alloc.BinArrRefDec(dst.data.handle);
    } else if (dst.type == Type::String) {
      alloc.StringRefDec(dst.data.handle);
    }
    dst.type = src.type;
    dst.data.data = src.data.data;
    src.type = Type::Null;
    src.data = {};
  }
  static void ShallowCopy(Allocator& alloc, Value& src, Value& dst) {
    dst.type = src.type;
    dst.data.data = src.data.data;
  }
};

struct ProgramConstants {
  std::vector<Value> binArrs;
  std::vector<Value> strings;
  ProgramConstants(Allocator& alloc, const Program& program) {
    for (auto& data : program.binArrConsts) {
      binArrs.emplace_back();
      binArrs.back().type = Value::Type::BinArr;
      binArrs.back().data.handle = alloc.NewBinArr();
      alloc.binArrs[binArrs.back().data.handle].data = data;
    }
    for (auto& data : program.stringConsts) {
      strings.emplace_back();
      strings.back().type = Value::Type::String;
      strings.back().data.handle = alloc.NewString();
      alloc.strings[strings.back().data.handle].data = data;
    }
  }
};

struct State;
struct Arguments {
  virtual Result at(State& state, const Value& indexOrKey, Value& out) = 0;
  virtual std::int64_t num() = 0;
};

// ==================== 指令名（错误信息用）====================
constexpr int kOpCount = (int)Opcode::Return + 1;
inline std::string opcodeName(short op) {
  static const std::string kNames[kOpCount] = {
      "Assign",    "PushNull",   "PushFalse",  "PushTrue",  "PushInt",
      "PushFloat", "PushString", "PushBinArr", "PushValue", "PushId",
      "Call",      "At",         "Pop",        "Minus",     "Not",
      "Pow",       "Mul",        "Div",        "IDiv",      "Mod",
      "Add",       "Sub",        "EQ",         "NE",        "LT",
      "LE",        "GT",         "GE",         "If",        "GoTo",
      "GetArg",    "ArgNum",     "Return",
  };
  if (op >= 0 && op < kOpCount)
    return kNames[op];
  return "Op(" + std::to_string(op) + ")";
}

struct API;

struct State {
  Allocator* alloc = nullptr;
  ProgramConstants* constants = nullptr;
  Program* program = nullptr;  // 正在执行的程序，不拥有
  API* api = nullptr;          // 指令表，不拥有
  Arguments* args = nullptr;   // 不拥有

  int i = 0;                     // 指令指针：下标进 program->opcodes
  std::vector<Value> variables;  // 变量槽位，长度 == program->variableNum
  std::vector<Value> stack;
  std::span<Value> returns;  // Return 的返回值
  std::vector<std::string> errors;

  Result Step();  // 执行一条指令
  Result Run();   // 一直执行到 Return 或指令流结束；出错立即停
  void SetAllocator(Allocator& alloc) { this->alloc = &alloc; }
  void SetProgramConstants(ProgramConstants& constants) {
    this->constants = &constants;
  }
  void SetProgram(Program& program) { this->program = &program; }
  void SetAPI(API& api) { this->api = &api; }
  void SetArguments(Arguments& args) { this->args = &args; }

  bool HasError() const { return !errors.empty(); }
  void Error(const std::string& msg) {
    errors.push_back(std::to_string(i) + ": " + msg);
  }
  // 栈顶下标一律「从栈顶数、1 起算」：AtTop(1) 就是 stack.back()。
  // 注意这里不能把循环变量写成 i——那是指针。
  Value& AtTop(int i) { return stack[stack.size() - i]; }
  void Pop() {
    stack.back().Clear2(*alloc);
    stack.pop_back();
  }
  void PopN(unsigned num) {
    for (unsigned k = 0; k < num; k++) {
      stack[stack.size() - 1 - k].Clear2(*alloc);
    }
    stack.erase(stack.end() - static_cast<std::ptrdiff_t>(num), stack.end());
  }
  void PushInt(int64_t val) {
    stack.emplace_back();
    stack.back().type = Value::Type::Integer;
    stack.back().data.integer = val;
  }
  void PushFloat(double val) {
    stack.emplace_back();
    stack.back().type = Value::Type::Float;
    stack.back().data.floating = val;
  }
  void ClearStack() {
    for (auto& v : stack) {
      v.Clear2(*alloc);
    }
    stack.clear();
    returns = {};
  }
  void ClearVariables() {
    for (auto& v : variables) {
      v.Clear2(*alloc);
    }
    variables.clear();
  }
  void Clear() {
    ClearStack();
    ClearVariables();
  }
  ~State() { Clear(); }
};

struct API {
  using OpFunc = void (*)(API&, State&);
  static void opAssign(API& a, State& s) {
    if (s.stack.size() < 2) {
      s.Error("stack underflow. ");
      return;
    }
    if (s.AtTop(2).type != Value::Type::Identifier) {
      s.Error("no implement for value type. ");
      return;
    }
    unsigned vIndex = s.AtTop(2).data.index;
    Value& val = s.stack.back();
    Value::Move(*s.alloc, val, s.variables[vIndex]);
    s.PopN(2);
  }
  static void opPushNull(API& a, State& s) { s.stack.emplace_back(); }
  static void opPushFalse(API& a, State& s) {
    s.stack.emplace_back();
    s.stack.back().type = Value::Type::Integer;
    s.stack.back().data.integer = 0;
  }
  static void opPushTrue(API& a, State& s) {
    s.stack.emplace_back();
    Value& val = s.stack.back();
    val.type = Value::Type::Integer;
    val.data.integer = 1;
  }
  static void opPushInt(API& a, State& s) {
    s.stack.emplace_back();
    Value& val = s.stack.back();
    val.type = Value::Type::Integer;
    ++s.i;
    unsigned intConstIdx = s.program->opcodes[s.i];
    val.data.integer = s.program->intConsts[intConstIdx];
  }
  static void opPushFloat(API& a, State& s) {
    s.stack.emplace_back();
    Value& val = s.stack.back();
    val.type = Value::Type::Float;
    ++s.i;
    unsigned floatConstIdx = s.program->opcodes[s.i];
    val.data.floating = s.program->floatConsts[floatConstIdx];
  }
  static void opPushString(API& a, State& s) {
    s.stack.emplace_back();
    Value& val = s.stack.back();
    ++s.i;
    unsigned stringConstIdx = s.program->opcodes[s.i];
    Value::Copy(*s.alloc, s.constants->strings[stringConstIdx], val);
  }
  static void opPushBinArr(API& a, State& s) {
    s.stack.emplace_back();
    Value& val = s.stack.back();
    ++s.i;
    unsigned binArrConstIdx = s.program->opcodes[s.i];
    Value::Copy(*s.alloc, s.constants->binArrs[binArrConstIdx], val);
  }
  static void opPushId(API& a, State& s) {
    s.stack.emplace_back();
    Value& val = s.stack.back();
    val.type = Value::Type::Identifier;
    ++s.i;
    val.data.index = s.program->opcodes[s.i];
  }
  static void opPushValue(API& a, State& s) {
    ++s.i;
    unsigned index = s.program->opcodes[s.i];
    s.stack.emplace_back();
    Value& val = s.stack.back();
    Value::Copy(*s.alloc, s.variables[index], val);
  }
  static void opCall(API& a, State& s) {
    // 不检查 Stack Underflow，因为在编译期检查。
    ++s.i;
    unsigned argNum = s.program->opcodes[s.i];
    if (s.AtTop(argNum + 1).type != Value::Type::HostFunction) {
      s.Error("\"Call\" can only call a function. ");
    }
    Value out;
    std::span<Value> args(s.stack.data() + s.stack.size() - argNum, argNum);
    s.AtTop(argNum + 1).data.hostFuncPtr(s, args, out);
    s.PopN(argNum);
    Value::Move(*s.alloc, out, s.stack.back());
  }
  static void opAt(API& a, State& s) {  // 不检查 Stack Underflow
    ++s.i;
    unsigned keyNum = s.program->opcodes[s.i];
    if (keyNum != 1) {
      s.Error("no implement for key num != 1. ");
      return;
    }
    Value& container = s.AtTop(2);
    Value& key = s.AtTop(1);
    if (key.type != Value::Type::Integer) {
      s.Error("index must be integer. ");
      return;
    }
    int64_t index = key.data.integer;
    int64_t result = 0;
    if (container.type == Value::Type::BinArr) {
      std::vector<char>& data = s.alloc->binArrs[container.data.handle].data;
      if (index < 0 || index >= data.size()) {
        s.Error("index out of range. ");
        return;
      }
      result = data[index];
    } else if (container.type == Value::Type::String) {
      std::u16string& data = s.alloc->strings[container.data.handle].data;
      if (index < 0 || index >= data.size()) {
        s.Error("index out of range. ");
        return;
      }
      result = data[index];
    } else {
      s.Error("no implement for container type. ");
      return;
    }
    s.PopN(keyNum + 1);
    s.PushInt(result);
  }
  static void opPop(API& a, State& s) { s.Pop(); }
  static void opMinus(API& a, State& s) {
    Value& val = s.stack.back();
    if (val.type == Value::Type::Integer) {  // 回绕，不检查溢出
      val.data.integer =
          static_cast<int64_t>(0u - static_cast<uint64_t>(val.data.integer));
    } else if (val.type == Value::Type::Float) {
      val.data.floating = -val.data.floating;
    } else {
      s.Error("\"Minus\" can only operate on integer or float. ");
    }
  }
  static void opNot(API& a, State& s) {
    Value& val = s.stack.back();
    if (val.type == Value::Type::Null) {
      val.type = Value::Type::Integer;
      val.data.integer = 1;
    } else if (val.type == Value::Type::Integer) {
      val.type = Value::Type::Integer;
      val.data.integer = val.data.integer == 0;
    } else if (val.type == Value::Type::Float) {
      val.type = Value::Type::Integer;
      val.data.integer = val.data.floating == 0;
    } else {
      s.Error("\"Not\" can only operate on integer or float. ");
    }
  }
  static void opPow(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    if (!checkArith(s, "Pow", left, right))
      return;
    Value result;
    // 两个整数且指数 >= 0 → 整数结果；负指数（如 `2 ^ -1`）→ Float(0.5)。
    // 与常量折叠 expr_optim.cpp 的 Pow 分支一致。
    if (left.type == Value::Type::Integer &&
        right.type == Value::Type::Integer && right.data.integer >= 0) {
      result.type = Value::Type::Integer;
      result.data.integer = intPow(left.data.integer, right.data.integer);
    } else {
      result.type = Value::Type::Float;
      result.data.floating = std::pow(asDouble(left), asDouble(right));
    }
    storeBinary(s, result);
  }
  static bool isNumber(const Value& val) {
    return val.type == Value::Type::Integer || val.type == Value::Type::Float;
  }
  static bool isSequence(const Value& val) {
    return val.type == Value::Type::BinArr || val.type == Value::Type::String;
  }
  // 数值视图：整数与浮点都读成 double。调用方保证 isNumber(val)。
  static double asDouble(const Value& val) {
    return val.type == Value::Type::Float
               ? val.data.floating
               : static_cast<double>(val.data.integer);
  }
  // 整数除法 / 取模：不检查溢出（回绕），但用无符号运算躲开 INT64_MIN / -1 的
  // 硬件陷阱 —— 那会让整个进程崩掉。商向零取整，余数符号跟被除数。调用方保证 b != 0。
  static int64_t intDiv(int64_t a, int64_t b) {
    const bool neg = (a < 0) != (b < 0);
    const uint64_t ua =
        a < 0 ? 0u - static_cast<uint64_t>(a) : static_cast<uint64_t>(a);
    const uint64_t ub =
        b < 0 ? 0u - static_cast<uint64_t>(b) : static_cast<uint64_t>(b);
    const uint64_t q = ua / ub;
    return neg ? static_cast<int64_t>(0u - q) : static_cast<int64_t>(q);
  }
  static int64_t intMod(int64_t a, int64_t b) {
    const bool neg = a < 0;
    const uint64_t ua =
        a < 0 ? 0u - static_cast<uint64_t>(a) : static_cast<uint64_t>(a);
    const uint64_t ub =
        b < 0 ? 0u - static_cast<uint64_t>(b) : static_cast<uint64_t>(b);
    const uint64_t r = ua % ub;
    return neg ? static_cast<int64_t>(0u - r) : static_cast<int64_t>(r);
  }
  // 整数快速幂，exp >= 0；回绕，不检查溢出
  static int64_t intPow(int64_t base, int64_t exp) {
    int64_t result = 1;
    uint64_t b = static_cast<uint64_t>(base);
    while (exp > 0) {
      if (exp & 1)
        result = static_cast<int64_t>(static_cast<uint64_t>(result) * b);
      exp >>= 1;
      if (exp > 0)
        b = b * b;
    }
    return result;
  }
  // 算术公共前置检查：null 不能参与算术；两侧都必须是数字。
  // 返回 false 时已经写好错误信息，调用方直接 return。
  static bool checkArith(State& s,
                         const char* op,
                         const Value& left,
                         const Value& right) {
    if (left.type == Value::Type::Null || right.type == Value::Type::Null) {
      s.Error(std::string("\"") + op + "\" cannot operate on null. ");
      return false;
    }
    if (!isNumber(left) || !isNumber(right)) {
      s.Error(std::string("\"") + op +
              "\" can only operate on integer or float. ");
      return false;
    }
    return true;
  }
  // 整数除以 0 → 报错（不做除法，否则硬件异常直接终止进程）。
  // 判定看**运算走哪条路径**：只有两侧都是整数才是整数除法，此时 0 除数必拦。
  // 任一侧是 Float 就走 IEEE，不拦（`1.0 / 0` 与 `1 / 0.0` 都得 inf，不能一个报错一个得 inf）。
  static bool checkIntZero(State& s,
                           const char* op,
                           const Value& left,
                           const Value& right) {
    if (left.type == Value::Type::Integer &&
        right.type == Value::Type::Integer && right.data.integer == 0) {
      s.Error(std::string("\"") + op + "\" division by zero. ");
      return false;
    }
    return true;
  }
  // 二元算术统一的收尾：弹出右操作数，结果写回左操作数的位置
  static void storeBinary(State& s, Value& result) {
    s.Pop();
    s.stack.back().Clear2(*s.alloc);
    Value::ShallowCopy(*s.alloc, result, s.stack.back());
  }
  static void opMul(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    if (left.type == Value::Type::Null || right.type == Value::Type::Null) {
      s.Error("\"Mul\" cannot operate on null. ");
      return;
    }
    Value result;
    if (isNumber(left) && isNumber(right)) {
      if (left.type == Value::Type::Integer &&
          right.type == Value::Type::Integer) {
        result.type = Value::Type::Integer;  // 回绕，不检查溢出
        result.data.integer =
            static_cast<int64_t>(static_cast<uint64_t>(left.data.integer) *
                                 static_cast<uint64_t>(right.data.integer));
      } else {
        result.type = Value::Type::Float;
        result.data.floating = asDouble(left) * asDouble(right);
      }
    } else if ((isSequence(left) && right.type == Value::Type::Integer) ||
               (left.type == Value::Type::Integer && isSequence(right))) {
      // 序列重复：`2 * "ab"` 与 `"ab" * 2` 都要成立 —— 取序列那一侧，
      // 不能想当然地用 left 的句柄（整数在左时那是垃圾值，会直接崩）。
      Value& seq = isSequence(left) ? left : right;
      const int64_t times =
          isSequence(left) ? right.data.integer : left.data.integer;
      if (times < 0) {
        s.Error("\"Mul\" cannot repeat a sequence by a negative number. ");
        return;
      }
      if (seq.type == Value::Type::BinArr) {
        result.type = Value::Type::BinArr;
        const unsigned resHandle = s.alloc->NewBinArr();
        const std::vector<char>& srcData = s.alloc->GetBinArr(seq.data.handle);
        std::vector<char>& resData = s.alloc->GetBinArr(resHandle);
        if (srcData.size() != 0 &&
            static_cast<uint64_t>(times) <=
                (std::numeric_limits<size_t>::max)() / srcData.size()) {
          resData.reserve(srcData.size() * static_cast<size_t>(times));
        }
        for (int64_t k = 0; k < times; ++k) {
          resData.insert(resData.end(), srcData.begin(), srcData.end());
        }
        result.data.handle = resHandle;
      } else {  // seq.type == Value::Type::String
        result.type = Value::Type::String;
        const unsigned resHandle = s.alloc->NewString();
        const std::u16string& srcData = s.alloc->GetString(seq.data.handle);
        std::u16string& resData = s.alloc->GetString(resHandle);
        if (srcData.size() != 0 &&
            static_cast<uint64_t>(times) <=
                (std::numeric_limits<size_t>::max)() / srcData.size()) {
          resData.reserve(srcData.size() * static_cast<size_t>(times));
        }
        for (int64_t k = 0; k < times; ++k) {
          resData.insert(resData.end(), srcData.begin(), srcData.end());
        }
        result.data.handle = resHandle;
      }
    } else {
      s.Error(
          "\"Mul\" can only operate on numbers, or repeat a string / bin array "
          "by an integer. ");
      return;
    }
    storeBinary(s, result);
  }
  static void opDiv(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    if (!checkArith(s, "Div", left, right) ||
        !checkIntZero(s, "Div", left, right))
      return;
    Value result;
    if (left.type == Value::Type::Integer &&
        right.type == Value::Type::Integer) {
      const int64_t x = left.data.integer, y = right.data.integer;
      // 除不尽 → 浮点数（`7 / 2` 是 `Float(3.5)`）；与常量折叠的规则一致，
      // 整除要用 `idiv`。
      if (intMod(x, y) == 0) {
        result.type = Value::Type::Integer;
        result.data.integer = intDiv(x, y);
      } else {
        result.type = Value::Type::Float;
        result.data.floating = static_cast<double>(x) / static_cast<double>(y);
      }
    } else {
      result.type = Value::Type::Float;
      result.data.floating = asDouble(left) / asDouble(right);
    }
    storeBinary(s, result);
  }
  static void opIDiv(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    if (!checkArith(s, "IDiv", left, right) ||
        !checkIntZero(s, "IDiv", left, right))
      return;
    Value result;
    if (left.type == Value::Type::Integer &&
        right.type == Value::Type::Integer) {
      result.type = Value::Type::Integer;  // 向零取整
      result.data.integer = intDiv(left.data.integer, right.data.integer);
    } else {
      // 含浮点：仍按数值整除（向零取整），结果保持浮点，不做 float→int 收窄。
      result.type = Value::Type::Float;
      result.data.floating = std::trunc(asDouble(left) / asDouble(right));
    }
    storeBinary(s, result);
  }
  static void opMod(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    if (!checkArith(s, "Mod", left, right) ||
        !checkIntZero(s, "Mod", left, right))
      return;
    Value result;
    if (left.type == Value::Type::Integer &&
        right.type == Value::Type::Integer) {
      result.type = Value::Type::Integer;  // 余数符号跟被除数
      result.data.integer = intMod(left.data.integer, right.data.integer);
    } else {
      result.type = Value::Type::Float;
      result.data.floating = std::fmod(asDouble(left), asDouble(right));
    }
    storeBinary(s, result);
  }
  static void opAdd(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    Value result;
    // null 不是「加法单位元」，也不与任何值做算术 —— 一律报错（§Add 规则）。
    if (left.type == Value::Type::Null || right.type == Value::Type::Null) {
      s.Error("\"Add\" cannot operate on null. ");
      return;
    }
    if (left.type == Value::Type::Integer) {
      if (right.type == Value::Type::Integer) {
        result.type = Value::Type::Integer;  // 回绕，不检查溢出
        result.data.integer =
            static_cast<int64_t>(static_cast<uint64_t>(left.data.integer) +
                                 static_cast<uint64_t>(right.data.integer));
      } else if (right.type == Value::Type::Float) {
        result.type = Value::Type::Float;
        result.data.floating = left.data.integer + right.data.floating;
      } else {
        s.Error("integer can only add integer or float. ");
        return;
      }
    } else if (left.type == Value::Type::Float) {
      if (right.type == Value::Type::Integer) {
        result.type = Value::Type::Float;
        result.data.floating = left.data.floating + right.data.integer;
      } else if (right.type == Value::Type::Float) {
        result.type = Value::Type::Float;
        result.data.floating = left.data.floating + right.data.floating;
      } else {
        s.Error("float can only add integer or float. ");
        return;
      }
    } else if (left.type == Value::Type::String &&
               right.type == Value::Type::String) {
      result.type = Value::Type::String;
      unsigned hRes = s.alloc->NewString();
      s.alloc->strings[hRes].data = s.alloc->strings[left.data.handle].data +
                                    s.alloc->strings[right.data.handle].data;
      result.data.handle = hRes;
    } else if (left.type == Value::Type::BinArr &&
               right.type == Value::Type::BinArr) {
      result.type = Value::Type::BinArr;
      unsigned hRes = s.alloc->NewBinArr();
      std::vector<char>& resData = s.alloc->GetBinArr(hRes);
      std::vector<char>& leftData = s.alloc->GetBinArr(left.data.handle);
      std::vector<char>& rightData = s.alloc->GetBinArr(right.data.handle);
      resData.reserve(leftData.size() + rightData.size());
      resData.insert(resData.end(), leftData.begin(), leftData.end());
      resData.insert(resData.end(), rightData.begin(), rightData.end());
      result.data.handle = hRes;
    } else {
      s.Error("\"Add\" can only operate on numbers, strings or bin arrays. ");
      return;
    }
    // result 是本地临时值，句柄所有权整体交给栈，用 ShallowCopy（不增减计数）。
    storeBinary(s, result);
  }
  static void opSub(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    if (!checkArith(s, "Sub", left, right))
      return;
    Value result;
    if (left.type == Value::Type::Integer) {
      if (right.type == Value::Type::Integer) {
        result.type = Value::Type::Integer;  // 回绕，不检查溢出
        result.data.integer =
            static_cast<int64_t>(static_cast<uint64_t>(left.data.integer) -
                                 static_cast<uint64_t>(right.data.integer));
      } else if (right.type == Value::Type::Float) {
        result.type = Value::Type::Float;
        result.data.floating = left.data.integer - right.data.floating;
      } else {
        s.Error("integer can only subtract integer or float. ");
        return;
      }
    } else if (left.type == Value::Type::Float) {
      if (right.type == Value::Type::Integer) {
        result.type = Value::Type::Float;
        result.data.floating = left.data.floating - right.data.integer;
      } else if (right.type == Value::Type::Float) {
        result.type = Value::Type::Float;
        result.data.floating = left.data.floating - right.data.floating;
      } else {
        s.Error("float can only subtract integer or float. ");
        return;
      }
    } else {
      s.Error("\"Sub\" can only operate on integer or float. ");
      return;
    }
    storeBinary(s, result);
  }
  static bool equals(State& s, const Value& left, const Value& right) {
    if (left.type == right.type) {
      if (left.type == Value::Type::Null) {
        return true;
      } else if (left.type == Value::Type::Integer ||
                 left.type == Value::Type::HostFunction) {
        return left.data.data == right.data.data;
      } else if (left.type == Value::Type::Float) {
        // 两个浮点数，值相同时，所有比特不一定相同
        return left.data.floating == right.data.floating;
      } else if (left.type == Value::Type::BinArr) {
        return s.alloc->GetBinArr(left.data.handle) ==
               s.alloc->GetBinArr(right.data.handle);
      } else if (left.type == Value::Type::String) {
        return s.alloc->strings[left.data.handle].data ==
               s.alloc->strings[right.data.handle].data;
      }
    } else if (left.type == Value::Type::Null ||
               right.type == Value::Type::Null) {
      return false;
    } else if (left.type == Value::Type::Integer) {
      if (right.type == Value::Type::Float)
        return double(left.data.integer) == right.data.floating;
      return false;
    } else if (left.type == Value::Type::Float) {
      if (right.type == Value::Type::Integer)
        return left.data.floating == double(right.data.integer);
      return false;
    }
    return false;
  }
  static bool lessThan(State& s, const Value& left, const Value& right) {
    if (left.type == Value::Type::Integer) {
      if (right.type == Value::Type::Integer) {
        return left.data.integer < right.data.integer;
      } else if (right.type == Value::Type::Float) {
        return left.data.integer < right.data.floating;
      }
    } else if (left.type == Value::Type::Float) {
      if (right.type == Value::Type::Integer) {
        return left.data.floating < right.data.integer;
      } else if (right.type == Value::Type::Float) {
        return left.data.floating < right.data.floating;
      }
    }
    s.Error("only on integer or float can be compared. ");
    return false;
  }
  static bool greaterThan(State& s, const Value& left, const Value& right) {
    return lessThan(s, right, left);
  }
  static void opEQ(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    Value result;
    result.type = Value::Type::Integer;
    result.data.integer = equals(s, left, right);
    s.Pop();
    s.stack.back().Clear2(*s.alloc);
    Value::ShallowCopy(*s.alloc, result, s.stack.back());
  }
  static void opNE(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    Value result;
    result.type = Value::Type::Integer;
    result.data.integer = !equals(s, left, right);
    s.Pop();
    s.stack.back().Clear2(*s.alloc);
    Value::ShallowCopy(*s.alloc, result, s.stack.back());
  }
  static void opLT(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    Value result;
    result.type = Value::Type::Integer;
    result.data.integer = lessThan(s, left, right);
    s.Pop();
    s.stack.back().Clear2(*s.alloc);
    Value::ShallowCopy(*s.alloc, result, s.stack.back());
  }
  static void opLE(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    Value result;
    result.type = Value::Type::Integer;
    result.data.integer = !greaterThan(s, left, right);
    s.Pop();
    s.stack.back().Clear2(*s.alloc);
    Value::ShallowCopy(*s.alloc, result, s.stack.back());
  }
  static void opGT(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    Value result;
    result.type = Value::Type::Integer;
    result.data.integer = greaterThan(s, left, right);
    s.Pop();
    s.stack.back().Clear2(*s.alloc);
    Value::ShallowCopy(*s.alloc, result, s.stack.back());
  }
  static void opGE(API& a, State& s) {
    Value& left = s.AtTop(2);
    Value& right = s.stack.back();
    Value result;
    result.type = Value::Type::Integer;
    result.data.integer = !lessThan(s, left, right);
    s.Pop();
    s.stack.back().Clear2(*s.alloc);
    Value::ShallowCopy(*s.alloc, result, s.stack.back());
  }
  static bool truely(State& s, const Value& val) {
    if (val.type == Value::Type::Null) {
      return false;
    } else if (val.type == Value::Type::Integer ||
               val.type == Value::Type::HostFunction) {
      return val.data.data != 0;
    } else if (val.type == Value::Type::Float) {
      return val.data.floating != 0.0;
    } else if (val.type == Value::Type::BinArr) {
      return s.alloc->GetBinArr(val.data.handle).size() != 0;
    } else if (val.type == Value::Type::String) {
      return s.alloc->GetString(val.data.handle).size() != 0;
    }
    return true;
  }
  static void opIf(API& a, State& s) {
    Value& cond = s.stack.back();
    const bool yes = truely(s, cond);
    s.Pop();  // 条件用完即弹，不再留在栈上
    ++s.i;    // 跳过操作数；条件成立时 Run 的 ++i 正好落到下一句
    unsigned short goToIdx = s.program->opcodes[s.i];
    if (!yes) {
      s.i = goToIdx - 1;
    }
  }
  static void opGoTo(API& a, State& s) {
    unsigned short goToIdx = s.program->opcodes[s.i + 1];  // 操作数在 i+1
    s.i = goToIdx - 1;
  }
  static void opGetArg(API& a, State& s) {
    if (!s.args) {
      s.Error("no args. ");
      return;
    }
    Value result;
    s.args->at(s, s.stack.back(), result);
    Value::Move(*s.alloc, result, s.stack.back());
  }
  static void opArgNum(API& a, State& s) {
    if (!s.args) {
      s.Error("no args. ");
      return;
    }
    s.PushInt(s.args->num());
  }
  static void opReturn(API& a, State& s) {
    ++s.i;
    unsigned short num = s.program->opcodes[s.i];
    s.returns = std::span<Value>(s.stack.data() + s.stack.size() - num, num);
    s.i = s.program->opcodes.size();
  }
  static inline const std::array<OpFunc, kOpCount> opFuncs{
      opAssign,    opPushNull,   opPushFalse,  opPushTrue,  opPushInt,
      opPushFloat, opPushString, opPushBinArr, opPushValue, opPushId,

      opCall,      opAt,         opPop,        opMinus,     opNot,
      opPow,       opMul,        opDiv,        opIDiv,      opMod,

      opAdd,       opSub,        opEQ,         opNE,        opLT,
      opLE,        opGT,         opGE,         opIf,        opGoTo,

      opGetArg,    opArgNum,     opReturn,
  };
};

Result State::Run() {
  while (i < program->opcodes.size()) {
    api->opFuncs[program->opcodes[i]](*api, *this);
    if (HasError())
      return Result::Error;
    ++i;
  }
  return Result::Success;
}
}  // namespace Stope::BasicVM
