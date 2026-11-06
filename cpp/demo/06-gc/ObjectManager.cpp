#include "ObjectManager.hpp"

#include <iostream>
#include <stdexcept>

#include "Runtime.hpp"

using namespace Stope;
using namespace std;

// ==================== 对象与描述符 ====================

BasicVM::Value ObjectManager::NewObject(int clsId) {
  Object* obj = alloc.NewObject();  // gc：挂链即诞生，refCount=0
  if (obj == nullptr) {
    return BasicVM::Value{};  // 顶到 maxNodes：Null 值，开口里 s.Error
  }
  obj->classId = clsId;
  obj->fields.resize(runtime->classes[clsId].properties.size());
  return ObjectToHandle(obj);
}

// 成员描述符 fields = [Integer 成员 id, 绑定对象 Handle/Null]：运行中按两层
// 整数查询定位（成员 id -> 类内 MemberRef，类取自绑定对象自己的 classId），
// kind 由查表揭晓——不做按名查找。
BasicVM::Value ObjectManager::NewMemberDesc(int memberId) {
  Object* d = alloc.NewObject();
  if (d == nullptr) {
    return BasicVM::Value{};  // 顶到 maxNodes
  }
  d->classId = kMemberDescClass;
  d->fields.resize(2);
  d->fields[0].type = BasicVM::Value::Type::Integer;
  d->fields[0].data.integer = memberId;
  return ObjectToHandle(d);
}

BasicVM::Value ObjectManager::NewCtorDesc(int clsId, int ctorId) {
  Object* d = alloc.NewObject();
  if (d == nullptr) {
    return BasicVM::Value{};  // 顶到 maxNodes
  }
  d->classId = kCtorDescClass;
  d->fields.resize(2);  // [类 id, 构造器 methods 下标]
  d->fields[0].type = BasicVM::Value::Type::Integer;
  d->fields[0].data.integer = clsId;
  d->fields[1].type = BasicVM::Value::Type::Integer;
  d->fields[1].data.integer = ctorId;
  return ObjectToHandle(d);
}

// 绑定描述符：fields = [成员 id, 对象 Handle]。对象引用经 SetField 挂上——
// 描述符活着，对象就活着（这是「正在执行的方法」里 self 对象的保命符：
// 方法 State 的变量持有描述符，描述符的字段持有对象，标记从根可达）。
BasicVM::Value ObjectManager::Bind(int memberId, const BasicVM::Value& obj) {
  Object* d = alloc.NewObject();
  if (d == nullptr) {
    return BasicVM::Value{};  // 顶到 maxNodes
  }
  d->classId = kMemberDescClass;
  d->fields.resize(2);
  d->fields[0].type = BasicVM::Value::Type::Integer;
  d->fields[0].data.integer = memberId;
  alloc.SetField(*d, 1, obj);
  return ObjectToHandle(d);
}

BasicVM::Value ObjectManager::Bind(const BasicVM::Value& memberDesc,
                                   const BasicVM::Value& obj) {
  Object* desc = HandleToObject(memberDesc);
  if (desc->classId != kMemberDescClass) {
    throw runtime_error("Bind: not a member descriptor");
  }
  return Bind((int)desc->fields[0].data.integer, obj);
}

// ==================== 三个开口 ====================

// 安全点：开口入口先同步根集合（扫描全部在册 State），再做本次操作。
// 「引用计数归零 -> 立即级联释放」的可靠性由这条顺序保证。
void ObjectManager::SafePoint() { alloc.SyncRoots(); }

// obj:<名>[p] -> 绑定成员描述符（属性引用 / 绑定方法都从这里出发）。
void ObjectManager::At(BasicVM::State& s, const BasicVM::Value& handle,
                       const BasicVM::Value& key, BasicVM::Value& out) {
  SafePoint();
  Object* desc = HandleToObject(handle);
  if (desc->classId != kMemberDescClass) {
    s.Error("not a member. ");
    return;
  }
  if (key.type != BasicVM::Value::Type::Handle) {
    s.Error("not an object. ");
    return;
  }
  out = Bind(handle, key);
  if (out.type != BasicVM::Value::Type::Handle) {
    s.Error("too many gc nodes. ");  // 描述符都分配不出来：上限到了
    return;
  }
}

// obj:<属性>[p] = v -> 写字段（走 SetField：旧值减引用可级联，新值加引用）。
// 两层查询：绑定对象自己的 classId 选类，成员 id 查该类的 memberById——
// kind 由表揭晓，同名成员在各类里落在不同位置也各归各。
void ObjectManager::Assign(BasicVM::State& s, const BasicVM::Value& handle,
                           const BasicVM::Value& value) {
  SafePoint();
  Object* desc = HandleToObject(handle);
  if (desc->classId != kMemberDescClass ||
      desc->fields[1].type != BasicVM::Value::Type::Handle) {
    s.Error("not assignable. ");
    return;
  }
  Object* obj = HandleToObject(desc->fields[1]);
  Class& cls = runtime->classes[obj->classId];              // 第一层：classId 选类
  auto it = cls.memberById.find((int)desc->fields[0].data.integer);
  if (it == cls.memberById.end() || it->second.kind != kMemberProp) {
    s.Error("not assignable. ");  // 该类没有这个属性，或同名成员是方法
    return;
  }
  alloc.SetField(*obj, (size_t)it->second.index, value);  // 第二层
}

// obj:<名>[p](...) -> 调方法；<Class>:<New>(...) -> 构造。
// demo 6 没有 obj:delete(p)：生命期归 gc 管。
void ObjectManager::Call(BasicVM::State& s, const BasicVM::Value& handle,
                         std::span<BasicVM::Value> args, BasicVM::Value& out) {
  SafePoint();
  Object* desc = HandleToObject(handle);
  if (desc->classId == kCtorDescClass) {
    Class& cls = runtime->classes[(size_t)desc->fields[0].data.integer];
    Method& m = cls.methods[(size_t)desc->fields[1].data.integer];
    BasicVM::Value objHandle = NewObject(cls.id);
    if (objHandle.type != BasicVM::Value::Type::Handle) {
      s.Error("too many gc nodes. ");  // 顶到 maxNodes：走正常错误通道
      return;
    }
    // 构造期间新生对象的 Handle 只在 C++ 局部 objHandle 与构造方法帧
    // 的 self 绑定描述符里——前者扫描看不到，后者是描述符字段引用，撑到
    // 返回值上栈、下个安全点被登记为根。
    runtime->PushMethodFrame(m, *HandleToObject(objHandle), args, false);
    out = std::move(objHandle);
    return;
  }
  if (desc->classId == kMemberDescClass) {
    int memberId = (int)desc->fields[0].data.integer;
    if (desc->fields[1].type != BasicVM::Value::Type::Handle) {
      s.Error("method not bound. ");  // demo 6 只支持 obj:<名>[p]() 绑定形式
      return;
    }
    Object* obj = HandleToObject(desc->fields[1]);
    Class& cls = runtime->classes[obj->classId];  // 第一层：classId 选类
    auto it = cls.memberById.find(memberId);
    if (it == cls.memberById.end() || it->second.kind != kMemberMethod) {
      s.Error("no method. ");  // 该类没有这个方法（属性不可调）
      return;
    }
    // 方法调用压帧：out 只放占位 Null——opCall 把它 Move 到调用方栈顶，
    // 方法帧弹栈时（FinishFrame）再回填真正的返回值。
    runtime->PushMethodFrame(cls.methods[(size_t)it->second.index], *obj, args, true);
    return;
  }
  s.Error("\"Call\" can only call a function. ");
}

// ==================== 析构与诊断 ====================

// gc 回收前回调（alloc.onFree）：跑 <delete>。此时字段还完整可读，析构体
// 可以打遗言（println）、也可以调自己的方法。业务对象才有析构；描述符
// （classId < 0）静默通过。
void ObjectManager::RunDestructor(Object& obj) {
  if (obj.classId < 0) {
    return;
  }
  Class& cls = runtime->classes[obj.classId];
  if (cls.deconstructorId >= 0) {
    runtime->InvokeMethod(cls.methods[cls.deconstructorId], obj, {}, nullptr);
  }
}

void ObjectManager::ReportLive() {
  alloc.ReportAlive();
  size_t rooted = alloc.rootSet.size();
  if (rooted == 0) {
    cout << "[gc] no roots: everything reachable has been freed\n";
  } else {
    cout << "[gc] roots keep " << rooted << " object(s) alive\n";
  }
}
