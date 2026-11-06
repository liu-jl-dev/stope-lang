//! gc.rs：对象分配器（对应 cpp/demo/06-gc/ 的 ObjectAllocator）。
//!
//! 引用计数的口径（与 C++ 版逐字对应，详见 cpp/docs/gc.md）：
//!   * VM 对 Handle 的复制不通知宿主（Clear2/Copy 对 Handle 是无操作——缝的
//!     设计），所以「栈/变量里此刻有哪些 Handle」只能靠扫描得知。
//!   * ref_count = 字段引用（set_field 精确维护）+ 根引用（sync_roots 同步）。
//!   * 安全点 = 每个 obj:* 开口入口 + collect 入口：扫描全部在册 State 的
//!     variables/stack/returns，Handle 一律算根，diff 出增减。**先加后删**——
//!     删除触发的级联发生在刚扫描完、根集合新鲜的瞬间，此时计数归零必然
//!     意味着 VM 侧再无 Handle，「立即级联释放」才可靠。
//! Rust 差异：没有 String/BinArr 引用计数（引擎管）；「释放」= 摘链 + 判死
//! + 清字段，剩余 Rc 引用消失后内存由 Rc 回收——没有 C++ 的 trash/
//! flush_trash（对象不会地址复用，悬空指针不存在）。root_set 的值存 ObjRef
//! （强引用）：根本来就是活的，登记表多一份引用不改变语义，还让「后删」
//! 阶段拿得到对象本体（裸指针键 + ObjRef 值，Rust 里最省事的组合）。

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use crate::object::{handle_of, obj_key, obj_of, Object, ObjRef};
use stope::Value;

pub struct GcAllocator {
    /// 链表哨兵：一个 class_id = usize::MAX 的哑节点，不占业务对象编号。
    anchor: ObjRef,
    root_set: RefCell<HashMap<*const RefCell<Object>, ObjRef>>,
    alive_count: RefCell<usize>,
    gc_trigger: RefCell<usize>,
    /// gc 节点上限（Rust 侧只计业务对象，描述符由 Rc 管）；0 = 不限。
    pub max_nodes: RefCell<usize>,
    collecting: RefCell<bool>,
    /// 上次 collect 释放数（诊断用）。
    pub last_freed: RefCell<usize>,
    /// 回收前回调：跑 <delete>（析构）。
    pub on_free: RefCell<Option<Box<dyn Fn(&ObjRef)>>>,
}

impl GcAllocator {
    pub fn new() -> Self {
        let anchor: ObjRef = Rc::new(RefCell::new(Object {
            self_id: 0,
            class_id: usize::MAX, // 哨兵标记
            fields: Vec::new(),
            gc_prev: None,
            gc_next: None,
            ref_count: 1,
            mark: false,
            dead: false,
        }));
        anchor.borrow_mut().gc_prev = Some(anchor.clone());
        anchor.borrow_mut().gc_next = Some(anchor.clone());
        GcAllocator {
            anchor,
            root_set: RefCell::new(HashMap::new()),
            alive_count: RefCell::new(0),
            gc_trigger: RefCell::new(64),
            max_nodes: RefCell::new(0),
            collecting: RefCell::new(false),
            last_freed: RefCell::new(0),
            on_free: RefCell::new(None),
        }
    }

    fn is_anchor(&self, o: &ObjRef) -> bool {
        Rc::ptr_eq(o, &self.anchor)
    }

    /// 新对象挂到链尾。返回 None = 顶到 max_nodes（开口里 s.error 报错）。
    /// roots 是本次安全点扫描出的根集合（maxNodes 触发的 collect 复用它）。
    pub fn new_object(&self, roots: &[ObjRef]) -> Option<Value> {
        if !*self.collecting.borrow()
            && self.max_nodes.borrow().clone() != 0
            && *self.alive_count.borrow() >= *self.max_nodes.borrow()
        {
            self.collect(roots); // 顶到上限：先回收再判断——gc 还有机会救
        }
        if self.max_nodes.borrow().clone() != 0 && *self.alive_count.borrow() >= *self.max_nodes.borrow()
        {
            return None;
        }
        let obj: ObjRef = Rc::new(RefCell::new(Object {
            self_id: crate::object::next_obj_id(),
            class_id: usize::MAX, // 由调用方（ObjectManager::new_object）改写
            fields: Vec::new(),
            gc_prev: None,
            gc_next: None,
            ref_count: 0,
            mark: false,
            dead: false,
        }));
        let prev = self.anchor.borrow().gc_prev.clone().unwrap();
        obj.borrow_mut().gc_next = Some(self.anchor.clone());
        obj.borrow_mut().gc_prev = Some(prev.clone());
        prev.borrow_mut().gc_next = Some(obj.clone());
        self.anchor.borrow_mut().gc_prev = Some(obj.clone());
        *self.alive_count.borrow_mut() += 1;
        Some(handle_of(&obj))
    }

    // ==================== 安全点：根同步 ====================

    // sync_roots 先加后删的原因：删除可能级联释放——先删会把「恰好刚被本轮
    // 扫描发现」的对象连同活引用一起级联释放。见 cpp/docs/gc.md §4。
    pub fn sync_roots(&self, found: &[ObjRef]) {
        if *self.collecting.borrow() {
            return; // 收集期间跳过重扫：根集合保持 collect 入口时的新鲜度
        }
        let found_keys: HashSet<*const RefCell<Object>> =
            found.iter().map(|o| obj_key(o)).collect();

        // 先加：本轮新发现的根 +1（同一对象在多个槽位出现只记一次根）。
        for o in found {
            if o.borrow().dead {
                continue; // 防御：死对象不可达
            }
            if self
                .root_set
                .borrow_mut()
                .insert(obj_key(o), o.clone())
                .is_none()
            {
                o.borrow_mut().ref_count += 1;
            }
        }
        // 后删：上一轮的根这轮没再出现 -> -1，归零立即级联。
        let stale: Vec<ObjRef> = self
            .root_set
            .borrow()
            .iter()
            .filter(|(k, _)| !found_keys.contains(*k))
            .map(|(_, o)| o.clone())
            .collect();
        for o in stale {
            self.root_set.borrow_mut().remove(&obj_key(&o)); // 无论死活都摘出根集合
            if o.borrow().dead {
                continue; // 同轮级联已收走
            }
            o.borrow_mut().ref_count -= 1;
            if o.borrow().ref_count < 1 {
                self.free_now(&o); // 刚确认：VM 侧再无 Handle，立即级联释放
            }
        }
    }

    // ==================== 引用计数 ====================

    fn add_ref(&self, v: &Value) {
        if let Some(o) = obj_of(v) {
            if !o.borrow().dead {
                o.borrow_mut().ref_count += 1;
            }
        }
    }

    fn del_ref(&self, v: &Value) {
        if let Some(o) = obj_of(v) {
            if o.borrow().dead {
                return;
            }
            o.borrow_mut().ref_count -= 1;
            if o.borrow().ref_count < 1 {
                self.free_now(&o); // 归零立即级联释放
            }
        }
    }

    // set_field 字段写入：旧引用先减（可能级联），再挂新引用。Rust 无 String
    // 引用计数（引擎管），无需 Clear2。
    pub fn set_field(&self, obj: &ObjRef, index: usize, v: &Value) {
        let old = obj.borrow().fields[index].clone();
        self.del_ref(&old);
        obj.borrow_mut().fields[index] = v.clone();
        self.add_ref(v);
    }

    // ==================== 释放（两条路径；Rust 无需延迟删除） ====================

    // free_now 计数归零路径：字段引用递减，归零的子对象**级联**释放。
    fn free_now(&self, obj: &ObjRef) {
        if obj.borrow().dead {
            return;
        }
        if let Some(f) = self.on_free.borrow().as_ref() {
            f(obj); // <delete> 先跑：字段还完整可读
        }
        let fields: Vec<Value> = obj.borrow_mut().fields.drain(..).collect();
        for v in &fields {
            if let Some(child) = obj_of(v) {
                let child_dead = child.borrow().dead;
                if !child_dead {
                    child.borrow_mut().ref_count -= 1;
                    if child.borrow().ref_count < 1 {
                        self.free_now(&child); // 级联
                    }
                }
            }
        }
        self.unlink(obj);
        // obj 的最后一个 Rc 消失时（调用方名单用完），内存由 Rc 回收。
    }

    // free_sweep sweep 路径：字段引用只减计数**不级联**——真死透的子对象
    // 马上就会在同一个 sweep 里被收走；还活着的（从根可达）计数不会归零。
    fn free_sweep(&self, obj: &ObjRef) {
        if obj.borrow().dead {
            return;
        }
        if let Some(f) = self.on_free.borrow().as_ref() {
            f(obj);
        }
        let fields: Vec<Value> = obj.borrow_mut().fields.drain(..).collect();
        for v in &fields {
            if let Some(child) = obj_of(v) {
                let child_dead = child.borrow().dead;
                if !child_dead && child.borrow().ref_count > 0 {
                    child.borrow_mut().ref_count -= 1;
                }
            }
        }
        self.unlink(obj);
    }

    fn unlink(&self, obj: &ObjRef) {
        let prev = obj.borrow().gc_prev.clone().unwrap();
        let next = obj.borrow().gc_next.clone().unwrap();
        prev.borrow_mut().gc_next = Some(next.clone());
        next.borrow_mut().gc_prev = Some(prev.clone());
        obj.borrow_mut().gc_prev = None;
        obj.borrow_mut().gc_next = None;
        obj.borrow_mut().dead = true;
        *self.alive_count.borrow_mut() -= 1;
    }

    // ==================== gc：标记清除 ====================

    // mark_from 迭代式标记：沿字段里的 Handle 引用铺开，显式栈防深对象图
    // 爆 Rust 栈。
    fn mark_from(&self, root: &ObjRef) {
        if root.borrow().dead || root.borrow().mark {
            return;
        }
        let mut work: Vec<ObjRef> = vec![root.clone()];
        root.borrow_mut().mark = true;
        while let Some(o) = work.pop() {
            let fields = o.borrow().fields.clone();
            for v in &fields {
                if let Some(c) = obj_of(v) {
                    let (c_dead, c_mark) = {
                        let b = c.borrow();
                        (b.dead, b.mark)
                    };
                    if !c_dead && !c_mark {
                        c.borrow_mut().mark = true;
                        work.push(c);
                    }
                }
            }
        }
    }

    pub fn collect(&self, roots: &[ObjRef]) {
        if *self.collecting.borrow() {
            return; // 析构里新建对象顶到阈值等重入：本次跳过，下个安全点再来
        }
        self.sync_roots(roots); // 收集前根集合先刷新到最新（此刻还没置位）

        *self.collecting.borrow_mut() = true;
        *self.last_freed.borrow_mut() = 0;

        // 标记：从全部根出发。
        for root in self.root_set.borrow().values() {
            self.mark_from(root);
        }

        // 清除：先收集死对象再逐个回收——on_free（析构）可能读写字段。
        let mut doomed: Vec<ObjRef> = Vec::new();
        let mut h = self.anchor.borrow().gc_next.clone().unwrap();
        while !self.is_anchor(&h) {
            if !h.borrow().mark {
                doomed.push(h.clone());
            }
            let nxt = h.borrow().gc_next.clone().unwrap();
            h = nxt;
        }
        for o in &doomed {
            if !o.borrow().dead {
                // 前面的析构可能已经级联/重入收走了它
                self.free_sweep(o);
                *self.last_freed.borrow_mut() += 1;
            }
        }

        // 清标记：只走还活着的链。
        let mut h = self.anchor.borrow().gc_next.clone().unwrap();
        while !self.is_anchor(&h) {
            h.borrow_mut().mark = false;
            let nxt = h.borrow().gc_next.clone().unwrap();
            h = nxt;
        }

        *self.collecting.borrow_mut() = false;
        let alive = *self.alive_count.borrow();
        *self.gc_trigger.borrow_mut() = std::cmp::max(64, alive * 2);
    }

    // dispose_all 退出兜底（C++ 的 ~ObjectAllocator）：逐个跑析构、判死——
    // 剩余对象（p）的「deleted: James」在这里打印；内存随后由 Rc 回收。
    pub fn dispose_all(&self) {
        // 注意：不能写 while let Some(mo) = self.anchor.borrow().gc_next…——该
        // 写法的 anchor 不可变借用在 2021 edition 下会活到整个循环体结束，
        // 循环体里 unlink 对 anchor 的 borrow_mut 会 panic（RefCell already
        // borrowed）。先取出判据、借用随语句结束，循环体才是干净的。
        loop {
            let mo = self.anchor.borrow().gc_next.clone().unwrap();
            if self.is_anchor(&mo) {
                break;
            }
            if let Some(f) = self.on_free.borrow().as_ref() {
                f(&mo);
            }
            self.unlink(&mo);
        }
    }

    // ==================== 诊断 ====================

    pub fn report_alive(&self) {
        let mut objs = 0;
        let mut h = self.anchor.borrow().gc_next.clone().unwrap();
        while !self.is_anchor(&h) {
            objs += 1;
            let nxt = h.borrow().gc_next.clone().unwrap();
            h = nxt;
        }
        println!("[gc] alive: {} object(s), root set {}", objs, self.root_set.borrow().len());
        let mut h = self.anchor.borrow().gc_next.clone().unwrap();
        while !self.is_anchor(&h) {
            let (sid, cid, rc, nxt) = {
                let b = h.borrow();
                (b.self_id, b.class_id, b.ref_count, b.gc_next.clone().unwrap())
            };
            println!("  {}  class {}  refCount {}", sid, cid, rc);
            h = nxt;
        }
    }

    // root_count 当前根集合大小（诊断用）。
    pub fn root_count(&self) -> usize {
        self.root_set.borrow().len()
    }
}
