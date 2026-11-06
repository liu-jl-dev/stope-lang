#pragma once

#include <map>
#include <memory>
#include <span>
#include <string>
#include <vector>

#include <stope/basic_vm.hpp>
#include "Object.hpp"
#include "Function.hpp"
#include "Class.hpp"
#include "API.hpp"
#include "ObjectManager.hpp"

// 一个执行帧：一个 State 加「弹栈时怎么收尾」的元数据。Runtime 持有帧栈，
// RunSteps 每次只跑栈顶帧——方法调用压帧、返回弹帧，调用方在栈里压住等
// 返回值。这是「把 State 显式放在一个栈里」的落地：单步粒度覆盖嵌套调用，
// 每帧预算（每帧限步）自然跨调用共享。
struct Frame {
  Stope::BasicVM::State state;
  Method* method = nullptr;  // nullptr = 入口帧（main）：弹栈不回写不回填
  Object* self = nullptr;    // 方法帧的 self（selfProps 回写目标）
  bool wantsReturn = false;  // true = 弹栈时把 returns[0] 回填调用方栈顶
                             // （构造器帧为 false：返回的是新对象，不走这里）
};

struct Runtime {
  Stope::BasicVM::Allocator basicAlloc;  // 所有 State 共享

  std::vector<Stope::BasicVM::HostFunction> hostFuncs;
  std::map<std::u16string, int> hostFuncMap;

  std::vector<Function> functions;  // 可移动（constAlloc 为 unique_ptr），无人跨扩容持有指针
  std::map<std::u16string, int> funcMap;

  std::vector<Class> classes;       // 同上；ObjectManager 持有的是类 id，不是指针
  std::map<std::u16string, int> classMap;

  // 成员名 -> 成员 id（全局，跨类共享同名 id）。obj:<名> 运行时两层查询的
  // 第一层的"名"在装配期就折算成了 id，运行中零字符串比较。
  std::map<std::u16string, int> memberNameMap;
  int NewMemberId(const std::u16string& name);  // 幂等：已存在返回原 id

  ObjectManager objMgr;
  API api;

  // ---------- 帧栈：显式调用栈 + 每帧限步驱动 ----------
  // 装配期结束后不再 NewClass，Method 地址稳定，Frame 里的指针安全。
  std::vector<std::unique_ptr<Frame>> frames;
  bool hadErrors = false;  // 任一帧出错置位（错误已打印，供入口返回码用）

  // 装配入口函数并压帧：宿主函数、"<Class>:<New>" 构造器描述符、obj:* 成员
  // 描述符绑进 entry 导出槽位。obj:* 命名等约定属于 Runtime 对文档的契约，
  // 嵌入者（main）只调这一行。
  Frame& PushEntryFrame(Function& entry);

  // 压入方法帧（Call 开口用）：装配方法 State、入栈，**不执行**——驱动循环
  // 自然切到栈顶帧。调用方停在 Call 指令的下一条，等本帧弹栈回填。
  void PushMethodFrame(Method& m, Object& self,
                       std::span<const Stope::BasicVM::Value> args,
                       bool wantsReturn);

  // 跑至多 maxSteps 条指令（弹栈不消耗步数）。返回 false = 帧栈已空、程序结束。
  bool RunSteps(int maxSteps);

  // 直接执行：一口气跑到帧栈清空。与 RunSteps 随时可切——先限步观察几帧、
  // 再 RunAll 跑完是同一驱动的两种用法。
  void RunAll();

  Runtime();

  void AddHostFunction(const std::u16string& name, Stope::BasicVM::HostFunction func);
  Class& NewClass();
  Function* FindFunction(const std::u16string& name);

  // 装配方法 State 并同步执行到结束。**只供 obj:delete 的析构路径用**：
  // <delete> 在 Delete 的清理序列中间被调用，之后还要驱逐描述符、清字段——
  // 必须一口气跑完，不能压进帧栈等驱动循环。
  void InvokeMethod(Method& m, Object& self, std::span<const Stope::BasicVM::Value> args,
                    Stope::BasicVM::Value* out);

 private:
  void SetupMethodState(Method& m, Object& self,
                        std::span<const Stope::BasicVM::Value> args,
                        Stope::BasicVM::State& state);
  // 绑定入口函数的导出槽位（PushEntryFrame 用）：宿主函数、构造器描述符、
  // obj:* 成员描述符。
  void BindEntry(Stope::BasicVM::State& state, Function& entry);
  // 摘出栈顶帧并收尾（RunSteps 的两个弹栈触发点共用）。
  void FinishTopFrame();
  // 帧收尾：错误打印、self:<属性> 槽位回写字段、返回值回填调用方栈顶
  // （opCall 已把占位 Null Move 到那里，覆盖即可）。本帧必须已摘出 frames。
  void FinishFrame(Frame& f);
};
