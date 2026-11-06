#include "Runtime.hpp"

#include <algorithm>
#include <iostream>
#include <limits>

using namespace Stope;
using namespace std;

Runtime::Runtime() {
  objMgr.runtime = this;
  api.objMgr = &objMgr;
  objMgr.alloc.basicAlloc = &basicAlloc;  // String/BinArr 的引用计数走共享分配器

  // gc 根扫描：分配器不认识 State，由 Runtime 供给「此刻全部在册 State 里
  // 的对象 Handle」。帧栈是大头（入口帧 + 压住的方法帧）；liveStates 只装
  // 同步旁路的析构 State。只有 Handle 算引用，其余类型一律跳过。
  objMgr.alloc.gatherRoots = [this](vector<Object*>& out) {
    auto scan = [&](BasicVM::State& s) {
      for (auto& v : s.variables) {
        if (v.type == BasicVM::Value::Type::Handle) {
          out.push_back(HandleToObject(v));
        }
      }
      for (auto& v : s.stack) {
        if (v.type == BasicVM::Value::Type::Handle) {
          out.push_back(HandleToObject(v));
        }
      }
      for (auto& v : s.returns) {
        if (v.type == BasicVM::Value::Type::Handle) {
          out.push_back(HandleToObject(v));
        }
      }
    };
    for (auto& f : frames) {
      scan(f->state);
    }
    for (BasicVM::State* s : liveStates) {
      scan(*s);
    }
  };
  // 析构回调：对象被回收前跑 <delete>（可能读写自身字段、调 println）。
  objMgr.alloc.onFree = [this](Object& o) { objMgr.RunDestructor(o); };
}

Class& Runtime::NewClass() {
  classes.emplace_back();
  classes.back().id = classes.size() - 1;
  // classMap 不在这里登记：此刻 name 还是空串，命名归 VisitClass。
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

// 装配入口帧的导出槽位。宿主函数：装配期已预算 (槽位下标, 宿主函数序号)，
// 直接绑；构造器："<Class>:<New 名>" 逐个绑（装配期按名查 exports，运行中
// 零查找）；成员描述符 obj:<属性>/<方法>：描述符只装成员 id（kind 由类的
// memberById 查表揭晓），运行时经两层整数查询定位。demo 6 没有
// obj:delete——生命期归 gc 管，<delete> 是回收时自动跑的析构函数。
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

  for (auto& [varIdx, hostIdx] : entry.hostBinds) {
    BasicVM::Value& slot = state.variables[varIdx];
    slot.type = BasicVM::Value::Type::HostFunction;
    slot.data.hostFuncPtr = hostFuncs[hostIdx];
  }
  for (auto& cls : classes) {
    for (auto& [name, methodId] : cls.constructorMap) {
      bind(cls.name + u":" + name, objMgr.NewCtorDesc(cls.id, methodId));
    }
  }
  for (auto& cls : classes) {
    for (auto& prop : cls.properties) {
      bind(u"obj:" + prop, objMgr.NewMemberDesc(NewMemberId(prop)));
    }
    for (auto& m : cls.methods) {
      if (m.name.empty() || cls.constructorMap.contains(m.name)) {
        continue;  // <delete> 无名不占 obj:；构造器不占 obj: 名
      }
      bind(u"obj:" + m.name, objMgr.NewMemberDesc(NewMemberId(m.name)));
    }
  }
}

// 装配方法 State（PushMethodFrame / InvokeMethod 共用）。方法体里的
// self:<属性> 槽位与对象字段按下标互达：进入时从字段复制，弹栈/返回后把
// 槽位写回字段（走 SetField，引用计数照常维护）；没碰的属性原样复制。
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

  // 方法体里的 Person:New / obj:<名> 描述符：装配期已创建并 Pin 住，逐个
  // 拷进槽位（Handle 是不透明引用，Copy 无副作用）。
  for (auto& [varIdx, v] : m.exportBinds) {
    BasicVM::Value& slot = state.variables[varIdx];
    slot.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, const_cast<BasicVM::Value&>(v), slot);
  }

  // self:<方法名> 槽位绑 self 的绑定方法描述符——方法体内 self:Greet() 直接
  // 调本类方法，无需 [对象]。demo 6 不再去重：每次调用一个新描述符，用完
  // 即垃圾，由 gc 收走。
  for (auto& [varIdx, memberId] : m.selfMethodBinds) {
    BasicVM::Value handle = objMgr.Bind(memberId, ObjectToHandle(&self));
    if (handle.type != BasicVM::Value::Type::Handle) {
      state.Error("too many gc nodes. ");  // 驱动循环的出错弹栈会让方法体直接不执行
      continue;
    }
    BasicVM::Value& slot = state.variables[varIdx];
    slot.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, handle, slot);
  }
}

// 压入方法帧，不执行——驱动循环（RunSteps）自然切到栈顶帧。调用方停在
// Call 的下一条指令；opCall 会把本开口返回的占位 Null Move 到调用方栈顶，
// 弹栈回填时覆盖它。本帧的 variables/stack 在 frames 里，安全点扫得到——
// 「正在执行方法的对象」经 self 绑定描述符的字段引用保活，与旧版等价。
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

// 帧收尾。selfProps 只含方法体实际引用的属性，没碰的零开销；回写走
// SetField——旧值减引用可能级联触发析构（同步旁路），此时本帧已摘出
// frames，字段清空不影响回填。
void Runtime::FinishFrame(Frame& f) {
  for (const auto& e : f.state.errors) {
    cout << "  vm: " << e << "\n";
    hadErrors = true;
  }
  if (f.method == nullptr) {
    return;  // 入口帧：没有 selfProps / 返回值
  }
  for (auto& [slotIdx, fieldIdx] : f.method->selfProps) {
    objMgr.alloc.SetField(*f.self, fieldIdx, f.state.variables[slotIdx]);
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

// 同步执行整个方法（<delete> 析构路径）：装配 + Run + 收尾。析构在级联
// 释放 / sweep 的中间被调用，跑完后调用方还要清字段、还字符串引用——
// 不能让出执行权。执行期间本 State 经 TrackState 进 gc 根扫描范围。
void Runtime::InvokeMethod(Method& m, Object& self,
                           std::span<const BasicVM::Value> args,
                           BasicVM::Value* out) {
  BasicVM::State state;
  SetupMethodState(m, self, args, state);

  TrackState(state);
  state.Run();
  UntrackState(state);
  for (const auto& e : state.errors) {
    cout << "  vm: " << e << "\n";
    hadErrors = true;
  }

  for (auto& [slotIdx, fieldIdx] : m.selfProps) {
    objMgr.alloc.SetField(self, fieldIdx, state.variables[slotIdx]);
  }
  if (out != nullptr && !state.returns.empty()) {
    BasicVM::Value::Copy(basicAlloc, state.returns[0], *out);
  }
}
