#include "ObjectManager.hpp"

#include <iostream>
#include <stdexcept>

#include "Runtime.hpp"

using namespace Stope;
using namespace std;

// ==================== 描述符 ====================

BasicVM::Value ObjectManager::NewObject(int clsId) {
  Object* obj = new Object{};  // 手动管理：obj:delete 释放
  obj->classId = clsId;
  obj->fields.resize(runtime->classes[clsId].properties.size());
  live.insert(obj);
  return ObjectToHandle(obj);
}

// 描述符 Handle（存 descPool 下标）-> Object*。返回的指针在 descPool 不 New 的
// 窗口内有效（各调用点均只读后即弃，安全）。
Object* ObjectManager::HandleToDesc(const Stope::BasicVM::Value& handle) {
  return &descPool.Get((unsigned)handle.data.handle);
}

// 成员描述符 fields = [Integer 成员 id, 绑定对象 Handle/Null]：运行中按两层
// 整数查询定位（成员 id -> 类内 MemberRef，类取自绑定对象自己的 classId），
// kind 由查表揭晓——不做按名查找。
BasicVM::Value ObjectManager::NewMemberDesc(int memberId) {
  unsigned h = descPool.New();
  Object& d = descPool.Get(h);
  d.classId = kMemberDescClass;
  d.fields.resize(2);
  d.fields[0].type = BasicVM::Value::Type::Integer;
  d.fields[0].data.integer = memberId;
  return DescToHandle(h);
}

BasicVM::Value ObjectManager::NewCtorDesc(int clsId, int ctorId) {
  unsigned h = descPool.New();
  Object& d = descPool.Get(h);
  d.classId = kCtorDescClass;
  d.fields.resize(2);  // [类 id, 构造器 methods 下标]
  d.fields[0].type = BasicVM::Value::Type::Integer;
  d.fields[0].data.integer = clsId;
  d.fields[1].type = BasicVM::Value::Type::Integer;
  d.fields[1].data.integer = ctorId;
  return DescToHandle(h);
}

// 按成员 id 直接绑定：每次新建一个绑定描述符（**不去重**），登记进 descByObject
// 以便 obj:delete 整组驱逐。绑定描述符只存 (成员 id, 对象地址)，创建后不可变。
BasicVM::Value ObjectManager::Bind(int memberId, const BasicVM::Value& obj) {
  Object* objPtr = HandleToObject(obj);
  unsigned h = descPool.New();
  Object& bound = descPool.Get(h);
  bound.classId = kMemberDescClass;
  bound.fields.resize(2);
  bound.fields[0].type = BasicVM::Value::Type::Integer;
  bound.fields[0].data.integer = memberId;
  BasicVM::Value::Copy(runtime->basicAlloc, const_cast<BasicVM::Value&>(obj), bound.fields[1]);
  descByObject[objPtr].push_back(h);  // 登记：obj:delete 时整组驱逐
  return DescToHandle(h);
}

BasicVM::Value ObjectManager::Bind(const BasicVM::Value& memberDesc,
                                   const BasicVM::Value& obj) {
  Object* desc = HandleToDesc(memberDesc);
  if (desc->classId != kMemberDescClass) {
    throw runtime_error("Bind: not a member descriptor");
  }
  return Bind((int)desc->fields[0].data.integer, obj);
}

// ==================== 三个开口 ====================

// obj:<名>[p] -> 绑定成员描述符（属性引用 / 绑定方法都从这里出发）。
void ObjectManager::At(BasicVM::State& s, const BasicVM::Value& handle,
                       const BasicVM::Value& key, BasicVM::Value& out) {
  Object* desc = HandleToDesc(handle);
  if (desc->classId != kMemberDescClass) {
    s.Error("not a member. ");
    return;
  }
  if (key.type != BasicVM::Value::Type::Handle) {
    s.Error("not an object. ");
    return;
  }
  out = Bind(handle, key);
}

// obj:<属性>[p] = v -> 写字段。描述符 [0]=成员 id、[1]=绑定对象。两层查询：
// 绑定对象自己的 classId 选类，成员 id 查该类的 memberById——kind 由表揭晓，
// 同名成员在各类里落在不同位置也各归各。
void ObjectManager::Assign(BasicVM::State& s, const BasicVM::Value& handle,
                           const BasicVM::Value& value) {
  Object* desc = HandleToDesc(handle);
  if (desc->classId != kMemberDescClass ||
      desc->fields[1].type != BasicVM::Value::Type::Handle) {
    s.Error("not assignable. ");
    return;
  }
  Object* obj = HandleToObject(desc->fields[1]);
  Class& cls = runtime->classes[obj->classId];              // 第一层：classId 选类
  auto it = cls.memberById.find((int)desc->fields[0].data.integer);
  if (it == cls.memberById.end()) {
    s.Error("not assignable. ");  // 该类没有这个成员
    return;
  }
  if (it->second.kind != kMemberProp) {
    s.Error("not assignable. ");  // 方法不可赋值
    return;
  }
  BasicVM::Value& slot = obj->fields[(size_t)it->second.index];  // 第二层
  slot.Clear2(*s.alloc);
  BasicVM::Value::Copy(*s.alloc, const_cast<BasicVM::Value&>(value), slot);
}

// obj:<名>[p](...) -> 调方法；obj:<名>(...) 直接调（delete 走这里，对象在实参里）；
// <Class>:<New>(...) -> 构造。
void ObjectManager::Call(BasicVM::State& s, const BasicVM::Value& handle,
                         std::span<BasicVM::Value> args, BasicVM::Value& out) {
  Object* desc = HandleToDesc(handle);
  if (desc->classId == kCtorDescClass) {
    Class& cls = runtime->classes[(size_t)desc->fields[0].data.integer];
    Method& m = cls.methods[(size_t)desc->fields[1].data.integer];
    if (maxObjects != 0 && live.size() >= maxObjects) {
      s.Error("too many objects. ");  // 手动管理：上限内也不自动回收，必须
                                      // obj:delete；走正常错误通道不 throw
      return;
    }
    BasicVM::Value objHandle = NewObject(cls.id);
    // 构造器压帧：返回值是新对象本身（out），不走「弹栈回填」通道。
    runtime->PushMethodFrame(m, *HandleToObject(objHandle), args, false);
    out = std::move(objHandle);
    return;
  }
  if (desc->classId == kMemberDescClass) {
    int memberId = (int)desc->fields[0].data.integer;
    // kind 不在描述符里，由类的 memberById 查表揭晓；而查表需要类，类来自
    // 绑定对象（obj:<名>[p]）或实参对象（obj:delete(p)）——二者得有其一。
    const BasicVM::Value* objVal = nullptr;
    if (desc->fields[1].type == BasicVM::Value::Type::Handle) {
      objVal = &desc->fields[1];  // obj:<名>[p] 绑定形式
    } else if (!args.empty() && args[0].type == BasicVM::Value::Type::Handle) {
      objVal = &args[0];          // obj:delete(p) 实参形式
    }
    if (objVal == nullptr) {
      if (!args.empty() && args[0].type != BasicVM::Value::Type::Handle) {
        s.Error("not an object. ");  // obj:<名>(实参)，但实参不是对象
      } else {
        s.Error("method not bound. ");  // obj:<方法> 未带 [对象] 或 ()
      }
      return;
    }
    Object* obj = HandleToObject(*objVal);
    Class& cls = runtime->classes[obj->classId];  // 第一层：classId 选类
    auto it = cls.memberById.find(memberId);
    if (it == cls.memberById.end()) {
      s.Error("no method. ");  // 该类没有这个成员
      return;
    }
    MemberRef ref = it->second;  // 第二层：成员 id -> 类内位置 + kind
    if (ref.kind == kMemberDelete) {
      Delete(s, *obj);  // 绑定形式与实参形式在此收敛
      return;
    }
    if (ref.kind != kMemberMethod) {
      s.Error("\"Call\" can only call a function. ");  // 属性不可调
      return;
    }
    // 方法调用压帧：out 只放占位 Null——opCall 把它 Move 到调用方栈顶，
    // 方法帧弹栈时（FinishFrame）再回填真正的返回值。
    runtime->PushMethodFrame(cls.methods[(size_t)ref.index], *obj, args, true);
    out = BasicVM::Value{};
    return;
  }
  s.Error("\"Call\" can only call a function. ");
}

// 跑 <delete>（可读写字段）-> 移出存活表 -> 驱逐绑定描述符 -> delete。
// 双重 delete 在这里拦下。
void ObjectManager::Delete(BasicVM::State& s, Object& obj) {
  if (live.erase(&obj) == 0) {
    s.Error("double delete. ");
    return;
  }
  Class& cls = runtime->classes[obj.classId];
  if (cls.deconstructorId >= 0) {
    runtime->InvokeMethod(cls.methods[cls.deconstructorId], obj, {}, nullptr);
  }
  // 驱逐该地址的全部绑定描述符：O(log A) 定位 + O(k) RefDec 回收。
  // 悬空绑定 Handle 若再用会别名到复用后的新绑定——同属「悬空 Handle 是
  // 程序错误」的纪律。
  auto it = descByObject.find(&obj);
  if (it != descByObject.end()) {
    for (unsigned h : it->second) {
      descPool.RefDec(h);
    }
    descByObject.erase(it);
  }
  // 清掉字段里的 String/BinArr 引用：Value 析构不会 RefDec，不手动清，
  // Allocator 里的字符串/二进制串条目引用计数卡住，永不可复用。
  for (auto& f : obj.fields) {
    f.Clear2(*s.alloc);
  }
  delete &obj;
}

void ObjectManager::ReportLive() {
  if (live.empty()) {
    cout << "[objects] all freed\n";
  } else {
    cout << "[objects] " << live.size() << " alive:";
    for (Object* p : live) {
      cout << " " << p << "(class " << p->classId << ")";
    }
    cout << "\n";
  }
  cout << "[descs] " << descPool.size() << " allocated, " << descPool.recycled.size()
       << " pooled\n";
}
