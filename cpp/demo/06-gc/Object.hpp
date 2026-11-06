#pragma once
#include <cstddef>
#include <functional>
#include <set>
#include <vector>
#include <stope/basic_vm.hpp>

// Handle 的 data.data 直接存对象指针（uint64 位型），demo 侧经这两个 helper 进出。
constexpr int kMemberDescClass = -2;  // obj:<名> 成员描述符
constexpr int kCtorDescClass = -3;    // <Class>:<New> 构造器描述符

// 成员的种类：查找表 memberById 的值。成员经两层整数查询定位（成员 id ->
// 类内 MemberRef，类取自绑定对象自己的 classId），不做按名查找。
constexpr int kMemberProp = 0;    // obj:<属性> —— Assign 写字段
constexpr int kMemberMethod = 1;  // obj:<方法> —— Call 调方法

// 类内成员的位置：kind 决定 index 落在哪个数组（properties / methods）。
struct MemberRef {
  int kind;
  int index;
};

// ---- GC 头：裸侵入式循环双向链表 + 引用计数 + 标记 ----
// demo 6 与 demo 5 的全部差异都在内存管理：对象不再手动 obj:delete，而是
//   1. 引用计数（字段引用精确维护 + 根引用在安全点同步）归零 -> 立即级联释放；
//   2. 循环引用由标记清除兜底（阈值触发 Collect）。
// 链表锚点是分配器内的哨兵头（anchor），不占对象编号——所有真实对象挂在
// anchor.next 与 anchor 之间。Handle 直存对象指针：GC 不搬移对象，堆节点
// 地址天然稳定，无需 id 间接层，demo 5 的全部访问路径原样保留。
struct GCHeader {
  GCHeader* prev = nullptr;
  GCHeader* next = nullptr;
  int64_t refCount = 0;  // 字段引用（精确）+ 根引用（安全点同步）
  int mark = 0;          // 0 未标记 / 1 已标记
  bool dead = false;     // 已摘链待删：级联与 sweep 的回收名单重叠时防双重释放
};

struct Object : GCHeader {
  int classId = -1;
  std::vector<Stope::BasicVM::Value> fields;  // 按下标对齐 Class::properties
};

Stope::BasicVM::Value ObjectToHandle(Object* p);
Object* HandleToObject(const Stope::BasicVM::Value& v);

// ---- 对象分配器 ----
// 引用计数的口径（demo 6 最需要想清楚的地方）：
//   * VM 对 Handle 的复制不通知宿主（Clear2/Copy 对 Handle 是无操作——缝的
//     设计），所以「栈/变量里此刻有哪些 Handle」只能靠扫描得知。
//   * refCount = 字段引用（SetField 精确维护）+ 根引用（SyncRoots 同步）。
//   * 安全点 = 每个 obj:* 开口入口 + Collect 入口：扫描全部在册 State 的
//     variables/stack/returns，Handle 一律算根，diff 出 RootAdd/RootDel。
//     **先加后删**——删除触发的级联发生在刚扫描完、根集合新鲜的瞬间，
//     此时计数归零必然意味着 VM 侧再无 Handle，「立即级联释放」才可靠。
//   * 归零释放只会发生在安全点路径上；对象若只被字段引用（无根引用），
//     字段覆盖触发的 DelRef 同样即时生效——它的 Handle 不在任何 State 里。
struct ObjectAllocator {
  Stope::BasicVM::Allocator* basicAlloc = nullptr;  // String/BinArr 引用计数
  GCHeader anchor;                          // 哨兵：anchor.next = 第一个对象
  std::set<Object*> rootSet;                // 当前认定的根对象集合
  std::vector<Object*> pinned;              // 宿主长期持有的对象（装配期描述符）：
                                            // 永久 +1 引用、Collect 恒标记
  size_t aliveCount = 0;                    // 链上真实对象数（诊断用）
  size_t maxNodes = 0;                      // gc 节点上限（业务对象 + 描述符都算）；
                                            // 顶到上限先 Collect 仍放不下则分配
                                            // 失败，开口报错。0 = 不限
                                            // （对齐 Parser / STML maxDepth 约定）
  bool collecting = false;                  // Collect 重入守卫
  size_t lastFreed = 0;                     // 上次 Collect 释放数（诊断用）
  std::vector<Object*> trash;               // 已摘链待 delete：安全点末尾统一冲刷

  // 安全点根扫描：宿主注册——枚举全部在册 State 的 variables/stack/returns，
  // 把 Handle 还原成 Object* 塞进参数。分配器不认识 BasicVM::State，只认 Value。
  std::function<void(std::vector<Object*>&)> gatherRoots;
  // 回收前回调：demo 在这里跑 <delete>（析构）。析构体里可以读写自己的字段，
  // 也可以调对象方法——安全点同步在收集期间被跳过（根集合保持入口时的
  // 新鲜度），但不要再新建大量对象：会重入 gc（有守卫不会崩，时机不可预期）。
  std::function<void(Object&)> onFree;

  ObjectAllocator() {
    anchor.next = &anchor;
    anchor.prev = &anchor;
  }
  ~ObjectAllocator();  // 退出兜底：逐个析构、还引用、释放内存
  ObjectAllocator(const ObjectAllocator&) = delete;
  ObjectAllocator& operator=(const ObjectAllocator&) = delete;

  [[nodiscard]] Object* NewObject();  // 挂链返回：refCount=0、classId=-1；
                                      // 存活数到阈值会先 Collect
  void Pin(Object* obj);              // 宿主长期持有：+1 且 Collect 恒标记
  void SyncRoots();                   // 安全点：重建根集合（先加后删）
  void Collect();                     // 标记清除：循环引用的兜底，阈值触发

  // 字段写入：旧值/新值是 Handle 就减/加引用；String/BinArr 照常 Clear2/Copy。
  void SetField(Object& obj, size_t index, const Stope::BasicVM::Value& v);

  // 引用计数 +/-1（Handle 之外的类型是空操作）。DelRef 归零立即级联释放。
  void AddRef(const Stope::BasicVM::Value& v);
  void DelRef(const Stope::BasicVM::Value& v);

  // 诊断：走一遍链表，报告存活对象与描述符。
  void ReportAlive();

private:
  void MarkFrom(Object* root);  // 迭代式标记（显式栈，防深链爆 C++ 栈）
  void FreeNow(Object* obj);    // 计数归零路径：减子引用且级联
  void FreeSweep(Object* obj);  // sweep 路径：减子引用不级联（死透的等下次 gc）
  void Unlink(Object* obj);     // 摘链 + dead 标记 + 存活数 -1
  void FlushTrash();            // 统一 delete trash 里的节点
};
