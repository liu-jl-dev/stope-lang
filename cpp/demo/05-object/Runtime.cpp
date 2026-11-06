#include "Runtime.hpp"

#include <algorithm>
#include <iostream>
#include <limits>

using namespace Stope;
using namespace std;

Runtime::Runtime() {
  objMgr.runtime = this;
  api.objMgr = &objMgr;
}

Class& Runtime::NewClass() {
  classes.emplace_back();
  classes.back().id = classes.size() - 1;
  classMap[classes.back().name] = classes.back().id;
  return classes.back();
}

int Runtime::NewMemberId(const std::u16string& name) {
  auto it = memberNameMap.find(name);
  if (it != memberNameMap.end()) {
    return it->second;
  }
  int id = (int)memberNameMap.size();
  memberNameMap.emplace(name, id);
  return id;
}

Function* Runtime::FindFunction(const std::u16string& name) {
  auto it = funcMap.find(name);
  return it == funcMap.end() ? nullptr : &functions[it->second];
}

void Runtime::AddHostFunction(const std::u16string& name,
                              Stope::BasicVM::HostFunction func) {
  hostFuncMap[name] = hostFuncs.size();
  hostFuncs.push_back(func);
}

void Runtime::BindEntry(BasicVM::State& state, Function& entry) {
  auto bind = [&](const u16string& name, const BasicVM::Value& v) {
    auto it = entry.program.exports.find(name);
    if (it == entry.program.exports.end()) {
      return;
    }
    BasicVM::Value& slot = state.variables[it->second];
    slot.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, const_cast<BasicVM::Value&>(v), slot);
  };

  // 宿主函数：装配期已预算 (槽位下标, 宿主函数序号)，直接绑。
  for (auto& [varIdx, hostIdx] : entry.hostBinds) {
    BasicVM::Value& slot = state.variables[varIdx];
    slot.type = BasicVM::Value::Type::HostFunction;
    slot.data.hostFuncPtr = hostFuncs[hostIdx];
  }
  // 构造器："<Class>:<New 名>" 逐个绑（装配期按名查 exports，运行中零查找）
  for (auto& cls : classes) {
    for (auto& [name, methodId] : cls.constructorMap) {
      bind(cls.name + u":" + name, objMgr.NewCtorDesc(cls.id, methodId));
    }
  }
  // 成员描述符 obj:<属性>/<方法>/<delete>：描述符只装成员 id（kind 由类的
  // memberById 查表揭晓），运行时经两层整数查询定位。
  for (auto& cls : classes) {
    for (auto& prop : cls.properties) {
      bind(u"obj:" + prop, objMgr.NewMemberDesc(NewMemberId(prop)));
    }
    for (auto& m : cls.methods) {
      if (m.name.empty() || cls.constructorMap.contains(m.name)) {
        continue;  // <delete> 走 obj:delete；构造器不占 obj: 名
      }
      bind(u"obj:" + m.name, objMgr.NewMemberDesc(NewMemberId(m.name)));
    }
    if (cls.deconstructorId >= 0) {
      bind(u"obj:delete", objMgr.NewMemberDesc(NewMemberId(u"delete")));
    }
  }
}

// 装配入口函数并压帧。绑定归 BindEntry（契约同旧版注释）。
Frame& Runtime::PushEntryFrame(Function& entry) {
  auto f = make_unique<Frame>();
  BasicVM::State& state = f->state;
  state.SetAPI(api);
  state.SetAllocator(basicAlloc);
  state.SetProgramConstants(*entry.constAlloc);
  state.SetProgram(entry.program);
  state.variables.resize(entry.program.variableNum);
  entry.InitializeState(state, {});
  BindEntry(state, entry);
  frames.push_back(std::move(f));
  return *frames.back();
}

// 装配方法 State（PushMethodFrame / InvokeMethod 共用）。方法体里的
// self:<属性> 槽位与对象字段按下标互达：进入时从字段复制，弹栈/返回后把
// 槽位写回字段；没碰的属性原样复制，无变化。
void Runtime::SetupMethodState(Method& m, Object& self,
                               std::span<const BasicVM::Value> args,
                               BasicVM::State& state) {
  state.SetAPI(api);
  state.SetAllocator(basicAlloc);
  state.SetProgramConstants(*m.constAlloc);
  state.SetProgram(m.program);
  state.variables.resize(m.program.variableNum);
  m.InitializeState(state, self, args);

  // 方法体里的宿主函数（println 等）绑进隐式导出槽位——装配期已预算好
  // (变量槽位下标, 宿主函数序号) 对，运行中零查找。
  for (auto& [varIdx, hostIdx] : m.hostBinds) {
    BasicVM::Value& slot = state.variables[varIdx];
    slot.type = BasicVM::Value::Type::HostFunction;
    slot.data.hostFuncPtr = hostFuncs[hostIdx];
  }

  // self:<方法名> 槽位绑 self 的绑定方法描述符——方法体内 self:Greet() 直接
  // 调本类方法，无需 [对象]：描述符创建时即绑定 self，Call 走绑定分支。
  // 去重缓存保证反复调用不重复分配。
  for (auto& [varIdx, memberId] : m.selfMethodBinds) {
    BasicVM::Value handle = objMgr.Bind(memberId, ObjectToHandle(&self));
    BasicVM::Value& slot = state.variables[varIdx];
    slot.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, handle, slot);
  }
}

// 压入方法帧，不执行——驱动循环（RunSteps）自然切到栈顶帧。调用方停在
// Call 的下一条指令；opCall 会把本开口返回的占位 Null Move 到调用方栈顶，
// 弹栈回填时覆盖它。
void Runtime::PushMethodFrame(Method& m, Object& self,
                              std::span<const BasicVM::Value> args,
                              bool wantsReturn) {
  auto f = make_unique<Frame>();
  SetupMethodState(m, self, args, f->state);
  f->method = &m;
  f->self = &self;
  f->wantsReturn = wantsReturn;
  frames.push_back(std::move(f));
}

// 每帧限步驱动：只跑栈顶帧，至多 maxSteps 条指令；帧弹栈（Return / 指令流
// 走完 / 出错中止当前函数）不消耗步数。false = 帧栈已空、程序结束。
bool Runtime::RunSteps(int maxSteps) {
  while (maxSteps > 0 && !frames.empty()) {
    BasicVM::State& s = frames.back()->state;
    if (s.i >= static_cast<int>(s.program->opcodes.size())) {
      FinishTopFrame();  // Return 已把返回值备好；弹栈不消耗步数
      continue;
    }
    if (s.Step() != Stope::Result::Success) {
      FinishTopFrame();  // 运行期错误：只中止当前函数，调用方继续
      continue;
    }
    --maxSteps;
  }
  return !frames.empty();
}

// 直接执行：一口气跑到帧栈清空。
void Runtime::RunAll() {
  while (RunSteps(std::numeric_limits<int>::max())) {
  }
}

// 帧收尾。selfProps 只含方法体实际引用的属性，没碰的零开销。
void Runtime::FinishFrame(Frame& f) {
  for (const auto& e : f.state.errors) {
    cout << "  vm: " << e << "\n";
    hadErrors = true;
  }
  if (f.method == nullptr) {
    return;  // 入口帧：没有 selfProps / 返回值
  }
  for (auto& [slotIdx, fieldIdx] : f.method->selfProps) {
    BasicVM::Value& dst = f.self->fields[fieldIdx];
    dst.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, f.state.variables[slotIdx], dst);
  }
  // 回填调用方栈顶（wantsReturn 帧）。构造器帧返回的是新对象本身，不走这里。
  if (f.wantsReturn && !frames.empty() && !f.state.returns.empty()) {
    BasicVM::Value& slot = frames.back()->state.stack.back();
    slot.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, f.state.returns[0], slot);
  }
}

void Runtime::FinishTopFrame() {
  std::unique_ptr<Frame> f = std::move(frames.back());
  frames.pop_back();
  FinishFrame(*f);
}

// 同步执行整个方法（obj:delete 的析构路径）：装配 + Run + 收尾。Delete 的
// 清理序列中间不能让出执行权——析构跑完后还要驱逐描述符、清字段。
void Runtime::InvokeMethod(Method& m, Object& self,
                           std::span<const BasicVM::Value> args,
                           BasicVM::Value* out) {
  BasicVM::State state;
  SetupMethodState(m, self, args, state);
  state.Run();
  for (const auto& e : state.errors) {
    cout << "  vm: " << e << "\n";
    hadErrors = true;
  }
  for (auto& [slotIdx, fieldIdx] : m.selfProps) {
    BasicVM::Value& dst = self.fields[fieldIdx];
    dst.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, state.variables[slotIdx], dst);
  }
  if (out != nullptr && !state.returns.empty()) {
    BasicVM::Value::Copy(basicAlloc, state.returns[0], *out);
  }
}
