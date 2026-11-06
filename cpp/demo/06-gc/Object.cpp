#include "Object.hpp"

#include <algorithm>
#include <iostream>
#include <string>

using namespace std;
using namespace Stope;

BasicVM::Value ObjectToHandle(Object* p) {
  BasicVM::Value v;
  v.type = BasicVM::Value::Type::Handle;
  v.data.data = reinterpret_cast<uint64_t>(p);
  return v;
}

Object* HandleToObject(const BasicVM::Value& v) {
  return reinterpret_cast<Object*>(v.data.data);
}

// ==================== 分配 ====================

// 新对象挂到链表尾（anchor 之前）。refCount 从 0 起算——出生即在调用方的
// 栈上，但根引用要到下一个安全点才同步；在那之前它由「即将产生的根」或
// 「字段引用」保护：安全点同步先于一切 DelRef，见 SyncRoots。
[[nodiscard]] Object* ObjectAllocator::NewObject() {
  if (!collecting && maxNodes != 0 && aliveCount >= maxNodes) {
    Collect();  // 顶到上限：先回收再判断——gc 还有机会救
  }
  if (maxNodes != 0 && aliveCount >= maxNodes) {
    return nullptr;  // 上限内仍放不下：交开口走 s.Error 报错
  }
  Object* obj = new Object{};
  obj->next = &anchor;
  obj->prev = anchor.prev;
  anchor.prev->next = obj;
  anchor.prev = obj;
  ++aliveCount;
  return obj;
}

// 宿主长期持有（装配期创建、存在 Method/宿主结构里的描述符等）：永久 +1，
// 根同步不碰它们，Collect 从这里出发标记——它们不在任何 State 里，扫描
// 看不见，不 Pin 会被当垃圾收走。
void ObjectAllocator::Pin(Object* obj) {
  if (!obj->dead) {
    pinned.push_back(obj);
    obj->refCount += 1;
  }
}

// ==================== 安全点：根同步 ====================

// 先加后删的原因：删除可能级联释放。假设先删后加——根集合里过期的引用
// 被摘除时，那个对象可能「恰好刚被本轮扫描发现在另一个 State 里」，先删
// 会把它连同还活着的引用一起级联释放，后加就是把悬空指针登记成根。
// 先加则保证：删除级联发生时，本轮新发现的根已经各就各位。
void ObjectAllocator::SyncRoots() {
  if (gatherRoots == nullptr || collecting) {
    return;  // 收集期间跳过重扫：根集合保持 Collect 入口时的新鲜度
  }
  vector<Object*> found;
  gatherRoots(found);

  // 先加：本轮新发现的根 +1（同一对象在多个槽位出现只记一次根）。
  for (Object* o : found) {
    if (o->dead) {
      continue;  // 防御：死对象不可达，不该出现在扫描结果里
    }
    if (rootSet.insert(o).second) {
      o->refCount += 1;
    }
  }
  // 后删：上一轮的根这轮没再出现 -> -1，归零立即级联。释放只摘链不 delete
  // （进 trash），本轮名单里的指针始终有效，dead 标志挡住重复处理。
  sort(found.begin(), found.end());
  vector<Object*> stale;
  set_difference(rootSet.begin(), rootSet.end(), found.begin(), found.end(),
                 back_inserter(stale));
  for (Object* o : stale) {
    rootSet.erase(o);  // 无论死活都摘出根集合（死进根集合只会是防御路径）
    if (o->dead) {
      continue;  // 同轮级联已收走
    }
    o->refCount -= 1;
    if (o->refCount < 1) {
      FreeNow(o);  // 刚确认：VM 侧再无 Handle，立即级联释放
    }
  }
  FlushTrash();
}

// ==================== 引用计数 ====================

void ObjectAllocator::AddRef(const BasicVM::Value& v) {
  if (v.type != BasicVM::Value::Type::Handle) {
    return;
  }
  Object* o = HandleToObject(v);
  if (!o->dead) {
    o->refCount += 1;
  }
}

void ObjectAllocator::DelRef(const BasicVM::Value& v) {
  if (v.type != BasicVM::Value::Type::Handle) {
    return;
  }
  Object* o = HandleToObject(v);
  if (o->dead) {
    return;
  }
  o->refCount -= 1;
  if (o->refCount < 1) {
    FreeNow(o);  // 归零立即级联释放
  }
}

// 字段写入：旧引用先减（可能级联释放旧目标——它不在任何 State 里，因为
// 每次开口都先做过根同步），再挂新引用。
void ObjectAllocator::SetField(Object& obj, size_t index,
                               const BasicVM::Value& v) {
  BasicVM::Value& slot = obj.fields[index];
  DelRef(slot);
  slot.Clear2(*basicAlloc);
  BasicVM::Value::Copy(*basicAlloc, const_cast<BasicVM::Value&>(v), slot);
  AddRef(slot);
}

// ==================== 释放（两条路径 + 延迟删除） ====================

// 计数归零路径：字段里的 Handle 引用递减，归零的子对象**级联**释放——
// 一串刚失去最后一丝引用的对象在同一瞬间全部析构。
void ObjectAllocator::FreeNow(Object* obj) {
  if (obj->dead) {
    return;
  }
  if (onFree) {
    onFree(*obj);  // <delete> 先跑：此时字段还完整可读
  }
  for (auto& v : obj->fields) {
    if (v.type == BasicVM::Value::Type::Handle) {
      Object* child = HandleToObject(v);
      if (!child->dead) {
        child->refCount -= 1;
        if (child->refCount < 1) {
          FreeNow(child);  // 级联
        }
      }
    }
    v.Clear2(*basicAlloc);  // String/BinArr 的引用计数还给 VM
  }
  Unlink(obj);
  trash.push_back(obj);  // 只摘链不 delete：调用方的名单里可能还有它
}

// sweep 路径：字段里的 Handle 引用只减计数**不级联**——真死透的子对象
// 这次没被标记，马上就会在同一个 sweep 里被收走；还活着的（从根可达）
// 计数不会归零。
void ObjectAllocator::FreeSweep(Object* obj) {
  if (obj->dead) {
    return;
  }
  if (onFree) {
    onFree(*obj);
  }
  for (auto& v : obj->fields) {
    if (v.type == BasicVM::Value::Type::Handle) {
      Object* child = HandleToObject(v);
      if (!child->dead && child->refCount > 0) {
        child->refCount -= 1;
      }
    }
    v.Clear2(*basicAlloc);
  }
  Unlink(obj);
  trash.push_back(obj);
}

void ObjectAllocator::Unlink(Object* obj) {
  obj->prev->next = obj->next;
  obj->next->prev = obj->prev;
  obj->dead = true;
  --aliveCount;
}

// 统一冲刷延迟删除。调用点：SyncRoots 末尾、Collect 末尾——此时所有持有
// 对象指针的局部名单（stale / doomed / found）都已用完，delete 绝不悬空。
void ObjectAllocator::FlushTrash() {
  for (Object* o : trash) {
    delete o;
  }
  trash.clear();
}

// ==================== gc：标记清除 ====================

// 迭代式标记：沿字段里的 Handle 引用铺开，显式栈防深对象图爆 C++ 栈。
void ObjectAllocator::MarkFrom(Object* root) {
  if (root->dead || root->mark != 0) {
    return;
  }
  vector<Object*> work{root};
  root->mark = 1;
  while (!work.empty()) {
    Object* o = work.back();
    work.pop_back();
    for (const auto& v : o->fields) {
      if (v.type != BasicVM::Value::Type::Handle) {
        continue;
      }
      Object* c = HandleToObject(v);
      if (!c->dead && c->mark == 0) {
        c->mark = 1;
        work.push_back(c);
      }
    }
  }
}

void ObjectAllocator::Collect() {
  if (collecting) {
    return;  // 析构里新建对象顶到阈值等重入：本次跳过，下个安全点再来
  }
  SyncRoots();  // 收集前根集合先刷新到最新（此刻还没置位，内层开口也可重扫，无害）

  collecting = true;
  lastFreed = 0;

  // 标记：从全部根与宿主长期持有的对象出发。
  for (Object* root : pinned) {
    MarkFrom(root);
  }
  for (Object* root : rootSet) {
    MarkFrom(root);
  }

  // 清除：先收集死对象再逐个回收——onFree（析构）可能读写字段，不能边走
  // 链表边摘。级联在本路径不发生（FreeSweep 只减计数）：活对象至少有一条
  // 从根来的引用撑着计数，环上成员互相递减不会把活对象减死。
  vector<Object*> doomed;
  for (GCHeader* h = anchor.next; h != &anchor; h = h->next) {
    Object* o = static_cast<Object*>(h);
    if (o->mark == 0) {
      doomed.push_back(o);
    }
  }
  for (Object* o : doomed) {
    if (!o->dead) {  // 前面的析构可能已经级联/重入收走了它
      FreeSweep(o);
      ++lastFreed;
    }
  }

  // 清标记：只走还活着的链。
  for (GCHeader* h = anchor.next; h != &anchor; h = h->next) {
    static_cast<Object*>(h)->mark = 0;
  }

  collecting = false;
  FlushTrash();
}

// ==================== 诊断 / 收尾 ====================

void ObjectAllocator::ReportAlive() {
  size_t objs = 0;
  size_t descs = 0;
  for (GCHeader* h = anchor.next; h != &anchor; h = h->next) {
    Object* o = static_cast<Object*>(h);
    if (o->classId >= 0) {
      ++objs;
    } else {
      ++descs;
    }
  }
  cout << "[gc] alive: " << objs << " object(s), " << descs
       << " descriptor(s), root set " << rootSet.size() << "\n";
  for (GCHeader* h = anchor.next; h != &anchor; h = h->next) {
    Object* o = static_cast<Object*>(h);
    cout << "  " << o << "  class " << o->classId << "  refCount "
         << o->refCount << "\n";
  }
}

ObjectAllocator::~ObjectAllocator() {
  // 程序退出兜底：逐个跑析构、还字符串引用，最后释放内存。
  GCHeader* h = anchor.next;
  while (h != &anchor) {
    GCHeader* nxt = h->next;
    Object* o = static_cast<Object*>(h);
    if (onFree && !o->dead) {
      onFree(*o);
    }
    for (auto& v : o->fields) {
      v.Clear2(*basicAlloc);
    }
    delete o;
    h = nxt;
  }
  FlushTrash();
}
