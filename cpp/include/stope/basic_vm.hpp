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

// 引用计数 + 句柄槽位复用的通用模板。字符串、字节数组（以及 demo 里的描述符）共用同一套
// New/RefInc/RefDec/复用堆逻辑，避免在 Allocator 里复制多份近乎相同的代码。访问走整数
// 句柄，引用计数语义与精简前的 Allocator 完全一致；模板在编译期单态化，VM 热路径零开销。
//
// Storage 默认 std::vector（String/BinArr 用：只按句柄索引访问、不取元素地址，最优）。
// 需要「元素地址长期稳定」的场景（如 demo5 把描述符当 Type::Handle 裸指针传递）传
// std::deque 即可获得稳定地址——两者都提供随机访问，recycled 复用堆不受影响。
template <class T, template <class...> class Storage = std::vector>
struct RefCountedPool {
  struct Entry {
    bool isDeleted = false;
    int refCount = 0;
    T data;
  };
  Storage<Entry> entries;
  std::vector<unsigned> recycled;  // 复用堆：std::greater 使最小 handle 优先复用

  [[nodiscard]] unsigned New() {
    unsigned handle;
    if (!recycled.empty()) {
      std::pop_heap(recycled.begin(), recycled.end(), std::greater<unsigned>());
      handle = recycled.back();
      recycled.pop_back();
      entries[handle].isDeleted = false;  // 复用前复位（原 BinArrData/StringData 复用路径漏复位 isDeleted，会让槽位卡死、无法再释放）
    } else {
      handle = entries.size();
      entries.push_back({});
    }
    entries[handle].refCount = 1;
    return handle;
  }
  void RefInc(unsigned handle) {
    if (handle < entries.size()) {
      entries[handle].refCount++;
    }
  }
  void RefDec(unsigned handle) {
    if (handle >= entries.size() || entries[handle].isDeleted) {
      return;
    }
    entries[handle].refCount--;
    if (entries[handle].refCount <= 0) {
      Delete(handle);
    }
  }
  T& Get(unsigned handle) { return entries[handle].data; }
  size_t size() const { return entries.size(); }  // 已分配槽位数（含已回收未复用）

 private:
  void Delete(unsigned handle) {
    entries[handle].isDeleted = true;
    entries[handle].data = T{};
    recycled.push_back(handle);
    std::push_heap(recycled.begin(), recycled.end(), std::greater<unsigned>());
  }
};

struct Allocator {
  RefCountedPool<std::vector<char>> binArrs;
  RefCountedPool<std::u16string> strings;
  Allocator() = default;
  Allocator(const Allocator&) = delete;
  Allocator& operator=(const Allocator&) = delete;

  // 薄包装：保持原 NewBinArr/NewString/RefInc/RefDec/Get* 接口不变，
  // Program、VM 各 op* 与所有宿主侧调用点无需改动。
  [[nodiscard]] unsigned NewBinArr() { return binArrs.New(); }
  void BinArrRefInc(unsigned handle) { binArrs.RefInc(handle); }
  void BinArrRefDec(unsigned handle) { binArrs.RefDec(handle); }
  [[nodiscard]] unsigned NewString() { return strings.New(); }
  void StringRefInc(unsigned handle) { strings.RefInc(handle); }
  void StringRefDec(unsigned handle) { strings.RefDec(handle); }
  std::vector<char>& GetBinArr(unsigned handle) { return binArrs.Get(handle); }
  std::u16string& GetString(unsigned handle) { return strings.Get(handle); }
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
    Handle,  // 宿主对象的不透明引用：VM 只存转、不解释。无引用计数 —— Clear2 /
             // Copy 对它天然无操作，值在栈与变量间复制都不会通知宿主；生命周期
             // 由宿主在安全点扫描 stack / variables 自行清点。所有算术与 At 都
             // 被既有守卫拒绝，等值比较是同一性（见 equals）。
  };
  union Data {
    uint64_t data;
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
  Allocator* alloc;
  std::vector<Value> binArrs;
  std::vector<Value> strings;
  ProgramConstants(const ProgramConstants&) = delete;  // 禁止拷贝
  ProgramConstants& operator=(const ProgramConstants&) = delete;
  // 移动 = 转移句柄所有权：句柄本身不失效（Allocator 才是拥有者），
  // 原对象两个向量清空，析构时 Clear() 自然无操作。
  ProgramConstants(ProgramConstants&& other) noexcept
      : alloc(other.alloc),
        binArrs(std::move(other.binArrs)),
        strings(std::move(other.strings)) {}
  ProgramConstants(Allocator& alloc, const Program& program) {
    this->alloc = &alloc;
    for (auto& data : program.binArrConsts) {
      binArrs.emplace_back();
      binArrs.back().type = Value::Type::BinArr;
      binArrs.back().data.handle = alloc.NewBinArr();
      alloc.GetBinArr(binArrs.back().data.handle) = data;
    }
    for (auto& data : program.stringConsts) {
      strings.emplace_back();
      strings.back().type = Value::Type::String;
      strings.back().data.handle = alloc.NewString();
      alloc.GetString(strings.back().data.handle) = data;
    }
  }
  void Clear() {
    for (auto& v : binArrs) {
      if (v.type == Value::Type::BinArr) {
        alloc->BinArrRefDec(v.data.handle);
      }
    }
    binArrs.clear();
    for (auto& v : strings) {
      if (v.type == Value::Type::String) {
        alloc->StringRefDec(v.data.handle);
      }
    }
    strings.clear();
  }
  ~ProgramConstants() { Clear(); }
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

  // ---- Handle（宿主引用）的三个开口，子类可改写；默认一律报错 ----
  // 与 PushId（VM 槽位引用）对称：Handle 是宿主引用，可 At 读、Assign 写、
  // Call 调。VM 不解释它的含义，遇到 Handle 只把值转发给这三个虚函数 ——
  // 生命周期归宿主（Allocator 不参与）。
  virtual void HandleAt(State& s,
                        const Value& handle,
                        const Value& key,
                        Value& out) {
    s.Error("no implement for container type. ");
  }
  virtual void HandleAssign(State& s, const Value& handle, const Value& value) {
    s.Error("no implement for value type. ");
  }
  virtual void HandleCall(State& s,
                          const Value& handle,
                          std::span<Value> args,
                          Value& out) {
    s.Error("\"Call\" can only call a function. ");
  }
  virtual ~API() = default;

  static void opAssign(API& a, State& s) {
    if (s.stack.size() < 2) {
      s.Error("stack underflow. ");
      return;
    }
    if (s.AtTop(2).type == Value::Type::Handle) {  // 宿主引用：写回宿主
      a.HandleAssign(s, s.AtTop(2), s.stack.back());
      if (s.HasError())
        return;  // 错误时栈保持原样，与其它错误路径一致
      s.PopN(2);
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
    if (s.AtTop(argNum + 1).type ==
        Value::Type::Handle) {  // 宿主引用：调经宿主
      Value out;
      std::span<Value> args(s.stack.data() + s.stack.size() - argNum, argNum);
      a.HandleCall(s, s.AtTop(argNum + 1), args, out);
      if (s.HasError())
        return;
      s.PopN(argNum);
      Value::Move(*s.alloc, out, s.stack.back());
      return;
    }
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
    if (container.type == Value::Type::Handle) {  // 宿主引用：读经宿主
      Value out;
      a.HandleAt(s, container, key, out);
      if (s.HasError())
        return;
      s.PopN(keyNum + 1);
      s.stack.emplace_back();
      Value::Move(*s.alloc, out, s.stack.back());
      return;
    }
    if (key.type != Value::Type::Integer) {
      s.Error("index must be integer. ");
      return;
    }
    int64_t index = key.data.integer;
    int64_t result = 0;
    if (container.type == Value::Type::BinArr) {
      std::vector<char>& data = s.alloc->GetBinArr(container.data.handle);
      if (index < 0 || index >= data.size()) {
        s.Error("index out of range. ");
        return;
      }
      result = data[index];
    } else if (container.type == Value::Type::String) {
      std::u16string& data = s.alloc->GetString(container.data.handle);
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
      s.alloc->GetString(hRes) = s.alloc->GetString(left.data.handle) +
                                  s.alloc->GetString(right.data.handle);
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
                 left.type == Value::Type::HostFunction ||
                 left.type == Value::Type::Handle) {  // 引用是同一性比较
        return left.data.data == right.data.data;
      } else if (left.type == Value::Type::Float) {
        // 两个浮点数，值相同时，所有比特不一定相同
        return left.data.floating == right.data.floating;
      } else if (left.type == Value::Type::BinArr) {
        return s.alloc->GetBinArr(left.data.handle) ==
               s.alloc->GetBinArr(right.data.handle);
      } else if (left.type == Value::Type::String) {
        return s.alloc->GetString(left.data.handle) ==
               s.alloc->GetString(right.data.handle);
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

// 执行 i 指向的一条指令（连同它的操作数）。Success = 这条跑完了、没有新错误。
//
// 三条约定（与 GDScript 侧 basic_vm.gd 的 State.step 一致）：
//   1. **终止条件由调用方用 i 判**，别写 `while (s.Step() == Result::Success)` ——
//      指令流走完之后 Step 返回 Success 但什么也不做，那个循环永远不结束。正确写法：
//        while (s.i < static_cast<int>(s.program->opcodes.size()) &&
//               s.Step() == Result::Success) { /* 每条之后检查 s */ }
//   2. 已经在错误态时不执行任何指令，直接返回 Error —— 否则手滑再调一次会把同一条
//      错指令跑第二遍、错误刷两条。**Run 没有这个预检**（它一出错就返回，调用方本就
//      不该续跑），这是 Step 与 Run 唯一的语义差别。
//   3. 返回值只管「这条有没有出错」，不管「还有没有下一条」。
inline Result State::Step() {
  if (HasError())
    return Result::Error;
  if (i >= static_cast<int>(program->opcodes.size()))
    return Result::Success;
  api->opFuncs[program->opcodes[i]](*api, *this);
  if (HasError())
    return Result::Error;
  ++i;
  return Result::Success;
}

// 一路跑到 Return 或指令流结束。复用 Step：header-only + inline，编译期就展开，
// 不会比手写循环慢 —— 这与 GDScript 侧「run 和 step 各写一遍」的取舍相反，那边是
// 真的每次调用都要付出解释器开销。
inline Result State::Run() {
  while (i < program->opcodes.size()) {
    if (Step() != Result::Success)
      return Result::Error;
  }
  return Result::Success;
}
}  // namespace Stope::BasicVM
