//! 编译器：把 AST 编译成 `Program` —— 对齐 `python/stope/compiler.py`
//! / `cpp/src/compiler.cpp`（C++ 为权威实现）。
//!
//! 【PushValue 与 PushId 的分工】`PushId` 压的是**槽位引用**（左值），只有两处产生：
//! 「有赋值的 let」左侧、`Assign` 左端是裸标识符时。其余读变量一律 `PushValue`。
//!
//! 【preExports】每个名字按给定顺序占一个「永不回收」的槽位；空名字与重名都是编译
//! 错误（行号记 0：这些名字不来自源码）。

use crate::ast::{Expr, Prog, Stmt};
use crate::common::Result as StopeResult;
use crate::opcode::{CustomOpcodeConfig, Opcode};
use crate::program::Program;
use crate::token::TokenType;
use std::collections::{BinaryHeap, HashMap, HashSet};
use std::rc::Rc;

// ====================================================================
// 作用域

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScopeKind {
    Block,
    File,
    While,
}

#[derive(Debug, Clone)]
struct Scope {
    kind: ScopeKind,
    /// 名字作用域：标识符 → 变量总表中的索引（While 不参与名字查找）
    id_map: HashMap<String, i32>,
    /// While：continue 跳回这里（循环开头）
    start_index: i32,
    /// While：待回填的 break 跳转目标（code 中的操作数位置）
    break_indices: Vec<i32>,
}

impl Scope {
    fn new(kind: ScopeKind) -> Self {
        Scope { kind, id_map: HashMap::new(), start_index: 0, break_indices: Vec::new() }
    }
}

/// 最小堆：变量索引回收用，保证总是复用最小的空位。
#[derive(Debug, Default)]
struct MinHeap {
    data: BinaryHeap<std::cmp::Reverse<i32>>,
    members: HashSet<i32>,
}

impl MinHeap {
    fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
    fn push(&mut self, v: i32) {
        self.data.push(std::cmp::Reverse(v));
        self.members.insert(v);
    }
    fn pop(&mut self) -> i32 {
        let v = self.data.pop().unwrap().0;
        self.members.remove(&v);
        v
    }
    fn has(&self, v: i32) -> bool {
        self.members.contains(&v)
    }
}

/// 变量分配器：所有变量统一编号；块结束时索引进入回收堆复用。
///
/// `new_unique_var` **不参与回收** —— 它给 export 与「未声明就使用的标识符」用。
#[derive(Debug, Default)]
struct VariableAllocator {
    vars: Vec<String>,
    recycled: MinHeap,
}

impl VariableAllocator {
    fn num(&self) -> i32 {
        self.vars.len() as i32
    }
    fn new_var(&mut self) -> i32 {
        if !self.recycled.is_empty() {
            let idx = self.recycled.pop();
            self.vars[idx as usize] = String::new();
            return idx;
        }
        let i = self.vars.len() as i32;
        self.vars.push(String::new());
        i
    }
    fn new_unique_var(&mut self, name: &str) -> i32 {
        let i = self.vars.len() as i32;
        self.vars.push(name.to_string()); // 不回收：导出变量必须一直占着一个位置
        i
    }
    fn free_var(&mut self, idx: i32) {
        if self.recycled.has(idx) {
            return; // 同一索引不重复回收
        }
        self.recycled.push(idx);
    }
}

/// 只记「相对变化」，最大值最后落到 `Program.required_stack_size`。
#[derive(Debug, Default)]
struct StackSizeManager {
    size: i32,
    max_size: i32,
}

impl StackSizeManager {
    fn inc(&mut self, n: i32) {
        self.size += n;
        if self.size > self.max_size {
            self.max_size = self.size;
        }
    }
    fn dec(&mut self, n: i32) {
        self.size -= n;
    }
    /// 分支汇合：某条路径被 GoTo 送走以后，把 size 扳回到「从别处跳到这里」时应有的
    /// 深度，否则 if / 短路运算符会把容量算成各分支深度之和。
    fn converge(&mut self, depth: i32) {
        self.size = depth;
    }
}

/// `Compiler(custom)` → `compile` 把 AST 写进一个 `Program`。
pub struct Compiler {
    custom_opcodes: Option<Rc<CustomOpcodeConfig>>,
    pub errors: Vec<String>,
    var_alloc: VariableAllocator,
    stack_size_mgr: StackSizeManager,
    scope_stack: Vec<Scope>,
    cur_line: i32,
}

impl Compiler {
    pub fn new(custom: Option<Rc<CustomOpcodeConfig>>) -> Self {
        Compiler {
            custom_opcodes: custom,
            errors: Vec::new(),
            var_alloc: VariableAllocator::default(),
            stack_size_mgr: StackSizeManager::default(),
            scope_stack: Vec::new(),
            cur_line: -1,
        }
    }

    /// 与 C++ 的 `Compiler::Reset` 一致：清错误、换自定义指令表。
    pub fn reset(&mut self, custom: Option<Rc<CustomOpcodeConfig>>) {
        self.errors.clear();
        self.custom_opcodes = custom;
    }

    // ---------------- 对外接口 ----------------

    /// 编译 `ast`，结果直接写进 `out`。
    ///
    /// 有错误时返回 `Result::Error` 并把 `out` 复原为空 —— 半成品 `Program` 跑不了。
    pub fn compile(&mut self, ast: &Prog, out: &mut Program, pre_exports: &[&str]) -> StopeResult {
        // reset_compile
        self.errors.clear();
        self.var_alloc = VariableAllocator::default();
        self.stack_size_mgr = StackSizeManager::default();
        self.scope_stack = vec![Scope::new(ScopeKind::File)];
        self.cur_line = -1;
        out.clear();

        self.export_pre_exports(out, pre_exports);
        self.visit_prog(ast, out);
        if !self.errors.is_empty() {
            out.clear();
            return StopeResult::Error;
        }
        out.variable_num = self.var_alloc.num();
        out.required_stack_size = self.stack_size_mgr.max_size;
        StopeResult::Success
    }

    /// 预导出：必须在 reset 之后调用。走 `new_unique_var`，先于源码里任何变量分配。
    fn export_pre_exports(&mut self, out: &mut Program, names: &[&str]) {
        for n in names {
            // 行号记 0：这些名字不来自源码
            if n.is_empty() {
                self.error(0, "empty name in pre-exports. ");
                continue;
            }
            if self.file_scope().id_map.contains_key(*n) {
                self.error(0, &format!("duplicate export of \"{}\". ", n));
                continue;
            }
            let idx = self.var_alloc.new_unique_var(n);
            self.declare_exported(out, n, idx);
        }
    }

    // ---------------- 指令输出 ----------------

    fn code_size(&self, out: &Program) -> i32 {
        out.opcodes.len() as i32
    }

    fn emit_op(&self, out: &mut Program, op: Opcode) {
        out.opcodes.push(op as i32);
    }

    /// 写一个操作数（索引 / 跳转目标）。超出 int16 要报错，否则回绕出来的跳转目标
    /// 会把 VM 带飞。
    fn emit_index(&mut self, out: &mut Program, mut idx: i32) {
        if !(-32768..=32767).contains(&idx) {
            let line = self.cur_line;
            self.error(line, "compile output too large: index exceeds int16. ");
            idx = 0;
        }
        out.opcodes.push(idx);
    }

    /// 占位：先写 -1，回填时才知道目标。
    fn emit_placeholder(&self, out: &mut Program) -> i32 {
        out.opcodes.push(-1);
        out.opcodes.len() as i32 - 1
    }

    fn patch_index(&mut self, out: &mut Program, pos: i32, mut target: i32) {
        if !(-32768..=32767).contains(&target) {
            let line = self.cur_line;
            self.error(line, "compile output too large: jump target exceeds int16. ");
            target = 0;
        }
        out.opcodes[pos as usize] = target;
    }

    /// 常量入池：相同的值只存一份，返回索引。
    fn const_index_i64(&self, pool: &mut Vec<i64>, v: i64) -> i32 {
        if let Some(i) = pool.iter().position(|&c| c == v) {
            return i as i32;
        }
        pool.push(v);
        pool.len() as i32 - 1
    }

    fn const_index_f64(&self, pool: &mut Vec<f64>, v: f64) -> i32 {
        if let Some(i) = pool.iter().position(|&c| c == v) {
            return i as i32;
        }
        pool.push(v);
        pool.len() as i32 - 1
    }

    fn const_index_str(&self, pool: &mut Vec<String>, v: &str) -> i32 {
        if let Some(i) = pool.iter().position(|c| c == v) {
            return i as i32;
        }
        pool.push(v.to_string());
        pool.len() as i32 - 1
    }

    fn const_index_bytes(&self, pool: &mut Vec<Vec<u8>>, v: &[u8]) -> i32 {
        if let Some(i) = pool.iter().position(|c| c == v) {
            return i as i32;
        }
        pool.push(v.to_vec());
        pool.len() as i32 - 1
    }

    fn error(&mut self, line: i32, msg: &str) {
        self.errors.push(format!("line {}: {}", line, msg));
    }

    // ---------------- 作用域 ----------------

    fn push_block_scope(&mut self) {
        self.scope_stack.push(Scope::new(ScopeKind::Block));
    }

    fn push_while_scope(&mut self) -> usize {
        self.scope_stack.push(Scope::new(ScopeKind::While));
        self.scope_stack.len() - 1
    }

    fn pop_scope(&mut self) {
        self.scope_stack.pop();
    }

    fn top_block_scope(&mut self) -> Option<usize> {
        (0..self.scope_stack.len())
            .rev()
            .find(|&i| matches!(self.scope_stack[i].kind, ScopeKind::Block | ScopeKind::File))
    }

    fn top_while_scope(&mut self) -> Option<usize> {
        (0..self.scope_stack.len())
            .rev()
            .find(|&i| self.scope_stack[i].kind == ScopeKind::While)
    }

    fn find_ident_host(&self, name: &str) -> Option<usize> {
        (0..self.scope_stack.len()).rev().find(|&i| {
            matches!(self.scope_stack[i].kind, ScopeKind::Block | ScopeKind::File)
                && self.scope_stack[i].id_map.contains_key(name)
        })
    }

    fn file_scope(&mut self) -> &mut Scope {
        &mut self.scope_stack[0]
    }

    // ---------------- 语句遍历 ----------------

    fn visit_prog(&mut self, p: &Prog, out: &mut Program) {
        for s in &p.stmts {
            self.visit_stmt(s, out);
        }
    }

    fn visit_stmt(&mut self, s: &Stmt, out: &mut Program) {
        self.cur_line = s.line();
        match s {
            Stmt::ExprStmt { expr, .. } => {
                self.visit_expr(expr, out);
                self.emit_op(out, Opcode::Pop);
                self.stack_size_mgr.dec(1);
            }
            Stmt::Let { line, has_assign, idents, expr } => {
                let Some(bs) = self.top_block_scope() else { return };
                if *has_assign {
                    // let a = expr; —— 只有一个标识符
                    if idents.is_empty() {
                        return;
                    }
                    let name = &idents[0];
                    if self.scope_stack[bs].id_map.contains_key(name) {
                        self.error(*line, &format!("duplicate declaration of '{}'. ", name));
                        return;
                    }
                    // 不要 visit 标识符本身（那会生成 PushValue 取值），这里是要绑定到新变量
                    let idx = self.var_alloc.new_var();
                    self.scope_stack[bs].id_map.insert(name.clone(), idx);
                    self.emit_op(out, Opcode::PushId);
                    self.emit_index(out, idx);
                    self.stack_size_mgr.inc(1);
                    if let Some(e) = expr {
                        self.visit_expr(e, out);
                    }
                    self.emit_op(out, Opcode::Assign);
                    self.stack_size_mgr.dec(2);
                } else {
                    for nm in idents {
                        if self.scope_stack[bs].id_map.contains_key(nm) {
                            self.error(*line, &format!("duplicate declaration of '{}'. ", nm));
                            continue;
                        }
                        let idx = self.var_alloc.new_var();
                        self.scope_stack[bs].id_map.insert(nm.clone(), idx);
                    }
                }
            }
            Stmt::Return { exprs, .. } => {
                for e in exprs {
                    self.visit_expr(e, out);
                }
                self.emit_op(out, Opcode::Return);
                self.emit_index(out, exprs.len() as i32);
                out.max_return_num = out.max_return_num.max(exprs.len() as i32);
                // Return 会让 VM 直接跳到 code 末尾，栈上的返回值不回收
            }
            Stmt::Export { line, idents } => {
                if self.scope_stack.len() > 1 {
                    self.error(*line, "\"export\" can only be used at top scope. ");
                }
                for name in idents {
                    if self.file_scope().id_map.contains_key(name) {
                        self.error(*line, &format!("duplicate export of \"{}\". ", name));
                        continue;
                    }
                    let idx = self.var_alloc.new_unique_var(name);
                    self.declare_exported(out, name, idx);
                }
            }
            Stmt::Block { prog, .. } => {
                self.push_block_scope();
                self.visit_prog(prog, out);
                // 先取回本块登记的局部变量再弹栈（对齐 python：pop 前存下 bs 引用）
                let idxs: Vec<i32> =
                    self.scope_stack.last().unwrap().id_map.values().copied().collect();
                self.pop_scope();
                for idx in idxs {
                    self.var_alloc.free_var(idx); // 回收局部变量索引
                }
            }
            Stmt::If { cond, first_prog, elifs, else_prog, .. } => {
                self.visit_expr(cond, out);
                self.emit_op(out, Opcode::If);
                self.stack_size_mgr.dec(1);
                let mut last_if_pos = self.emit_placeholder(out); // 条件为假时跳到这里
                self.visit_body_as_block(first_prog, out);
                self.emit_op(out, Opcode::GoTo); // 分支走完，跳出整个 if
                let mut goto_end_indices = vec![self.emit_placeholder(out)];
                self.patch_index(out, last_if_pos, self.code_size(out));
                for ei in elifs {
                    self.visit_expr(&ei.cond, out);
                    self.emit_op(out, Opcode::If);
                    self.stack_size_mgr.dec(1);
                    last_if_pos = self.emit_placeholder(out);
                    self.visit_body_as_block(&ei.prog, out);
                    self.emit_op(out, Opcode::GoTo);
                    goto_end_indices.push(self.emit_placeholder(out));
                    self.patch_index(out, last_if_pos, self.code_size(out));
                }
                if let Some(ep) = else_prog {
                    self.visit_body_as_block(ep, out);
                }
                let end = self.code_size(out);
                for pos in goto_end_indices {
                    self.patch_index(out, pos, end);
                }
            }
            Stmt::While { cond, prog, .. } => {
                let ws = self.push_while_scope();
                self.scope_stack[ws].start_index = self.code_size(out); // continue 回到这里
                let mut case_goto_end_pos = -1;
                if let Some(c) = cond {
                    // while cond { } —— cond 可省
                    self.visit_expr(c, out);
                    self.emit_op(out, Opcode::If);
                    self.stack_size_mgr.dec(1);
                    case_goto_end_pos = self.emit_placeholder(out);
                }
                self.visit_body_as_block(prog, out);
                self.emit_op(out, Opcode::GoTo);
                let start = self.scope_stack[ws].start_index;
                self.emit_index(out, start);
                let breaks: Vec<i32> = self.scope_stack[ws].break_indices.clone();
                for pos in breaks {
                    self.patch_index(out, pos, self.code_size(out));
                }
                // 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标。
                if case_goto_end_pos >= 0 {
                    let end = self.code_size(out);
                    self.patch_index(out, case_goto_end_pos, end);
                }
                self.pop_scope();
            }
            Stmt::Assign { left, right, .. } => {
                if let Expr::Ident(_, name) = left.as_ref() {
                    // 赋值左端的裸标识符要压【槽位】而不是值，否则 Assign 无处可存。
                    let idx = self.ident_slot(out, name);
                    self.emit_op(out, Opcode::PushId);
                    self.emit_index(out, idx);
                    self.stack_size_mgr.inc(1);
                } else {
                    // 可能是使用者设计的数组元素引用、对象成员引用等。压入值。
                    self.visit_expr(left, out);
                }
                self.visit_expr(right, out);
                self.emit_op(out, Opcode::Assign);
                self.stack_size_mgr.dec(2);
            }
            Stmt::Break(line) => {
                let Some(ws) = self.top_while_scope() else {
                    self.error(*line, "cannot use \"break\" outside of a loop. ");
                    return;
                };
                self.emit_op(out, Opcode::GoTo);
                let pos = self.emit_placeholder(out);
                self.scope_stack[ws].break_indices.push(pos);
            }
            Stmt::Continue(line) => {
                let Some(ws) = self.top_while_scope() else {
                    self.error(*line, "cannot use \"continue\" outside of a loop. ");
                    return;
                };
                self.emit_op(out, Opcode::GoTo);
                let start = self.scope_stack[ws].start_index;
                self.emit_index(out, start);
            }
        }
    }

    // ---------------- 表达式遍历 ----------------

    fn visit_expr(&mut self, e: &Expr, out: &mut Program) {
        self.cur_line = e.line();
        match e {
            Expr::Err(_) => {} // 失败路径的裸节点：不产出指令
            Expr::Null(_) => {
                self.emit_op(out, Opcode::PushNull);
                self.stack_size_mgr.inc(1);
            }
            Expr::Bool(_, v) => {
                self.emit_op(out, if *v { Opcode::PushTrue } else { Opcode::PushFalse });
                self.stack_size_mgr.inc(1);
            }
            Expr::Int(_, v) => {
                self.emit_op(out, Opcode::PushInt);
                let idx = self.const_index_i64(&mut out.int_consts, *v);
                self.emit_index(out, idx);
                self.stack_size_mgr.inc(1);
            }
            Expr::Float(_, v) => {
                self.emit_op(out, Opcode::PushFloat);
                let idx = self.const_index_f64(&mut out.float_consts, *v);
                self.emit_index(out, idx);
                self.stack_size_mgr.inc(1);
            }
            Expr::Str(_, v) => {
                self.emit_op(out, Opcode::PushString);
                let idx = self.const_index_str(&mut out.string_consts, v);
                self.emit_index(out, idx);
                self.stack_size_mgr.inc(1);
            }
            Expr::BinArr(_, v) => {
                self.emit_op(out, Opcode::PushBinArr);
                let idx = self.const_index_bytes(&mut out.binarr_consts, v);
                self.emit_index(out, idx);
                self.stack_size_mgr.inc(1);
            }
            Expr::Ident(_, name) => {
                let idx = self.ident_slot(out, name);
                self.emit_op(out, Opcode::PushValue); // 压的是变量的【值】；要槽位请用 PushId
                self.emit_index(out, idx);
                self.stack_size_mgr.inc(1);
            }
            Expr::Argc(_) => {
                self.emit_op(out, Opcode::ArgNum);
                self.stack_size_mgr.inc(1);
            }
            Expr::Args { key_expr, .. } => {
                if let Some(k) = key_expr {
                    self.visit_expr(k, out);
                }
                self.emit_op(out, Opcode::GetArg); // 弹下标、压结果，栈大小不变
            }
            Expr::UnaryOp { op, expr, .. } => {
                self.visit_expr(expr, out);
                match op {
                    TokenType::Not => self.emit_op(out, Opcode::Not),
                    TokenType::Sub => self.emit_op(out, Opcode::Minus),
                    _ => {}
                }
                // 一元指令：弹 1 压 1，栈大小不变
            }
            Expr::BinaryOp { op, left, right, .. } => {
                match op {
                    TokenType::Or => {
                        self.visit_or_expr(left, right, out);
                        return;
                    }
                    TokenType::And => {
                        self.visit_and_expr(left, right, out);
                        return;
                    }
                    _ => {}
                }
                self.visit_expr(left, out);
                self.visit_expr(right, out);
                self.emit_op(out, binary_opcode(*op));
                self.stack_size_mgr.dec(1); // 弹 2 压 1
            }
            Expr::Call { callee, args, .. } => {
                self.visit_expr(callee, out);
                for a in args {
                    self.visit_expr(a, out);
                }
                self.emit_op(out, Opcode::Call);
                self.emit_index(out, args.len() as i32);
                self.stack_size_mgr.dec(args.len() as i32); // callee + args 换成 1 个返回值
            }
            Expr::At { container, key_exprs, .. } => {
                self.visit_expr(container, out);
                for k in key_exprs {
                    self.visit_expr(k, out);
                }
                self.emit_op(out, Opcode::At);
                self.emit_index(out, key_exprs.len() as i32);
                self.stack_size_mgr.dec(key_exprs.len() as i32);
            }
            Expr::CustomOpcode { line, opcode_name, args, .. } => {
                let info = self.custom_opcodes.as_ref().and_then(|c| c.find(opcode_name)).copied();
                let Some(info) = info else {
                    self.error(*line, &format!("undefined custom opcode \"{}\". ", opcode_name));
                    return;
                };
                if !info.is_var_arg && info.arg_num != args.len() as i32 {
                    self.error(
                        *line,
                        &format!(
                            "custom opcode \"{}\" expected {} args, but got {}. ",
                            opcode_name, info.arg_num, args.len()
                        ),
                    );
                }
                for a in args {
                    self.visit_expr(a, out);
                }
                self.emit_op_raw(out, info.opcode);
                if info.is_var_arg {
                    self.emit_index(out, args.len() as i32);
                }
                // 自定义指令没有 callee 入栈，结果仍占 1 格 => dec(参数个数 - 1)
                self.stack_size_mgr.dec(args.len() as i32 - 1);
            }
        }
    }

    fn emit_op_raw(&self, out: &mut Program, op: i32) {
        out.opcodes.push(op);
    }

    /// 短路或：任一侧为真就 PushTrue，两条路径都在栈上留下恰好 1 个结果。
    fn visit_or_expr(&mut self, left: &Expr, right: &Expr, out: &mut Program) {
        self.visit_expr(left, out);
        self.emit_op(out, Opcode::If);
        self.stack_size_mgr.dec(1);
        let first_if_pos = self.emit_placeholder(out);
        let mut depth_at_if_target = self.stack_size_mgr.size; // If 已弹掉条件 = 汇合点深度
        self.emit_op(out, Opcode::PushTrue);
        self.stack_size_mgr.inc(1);
        self.emit_op(out, Opcode::GoTo);
        let goto_end1 = self.emit_placeholder(out);
        self.patch_index(out, first_if_pos, self.code_size(out));
        self.stack_size_mgr.converge(depth_at_if_target); // 后面接的是「左侧为假」这条路径

        self.visit_expr(right, out);
        self.emit_op(out, Opcode::If);
        self.stack_size_mgr.dec(1);
        let second_if_pos = self.emit_placeholder(out);
        depth_at_if_target = self.stack_size_mgr.size;
        self.emit_op(out, Opcode::PushTrue);
        self.stack_size_mgr.inc(1);
        self.emit_op(out, Opcode::GoTo);
        let goto_end2 = self.emit_placeholder(out);
        self.patch_index(out, second_if_pos, self.code_size(out));
        self.stack_size_mgr.converge(depth_at_if_target);

        self.emit_op(out, Opcode::PushFalse); // 两侧都不成立
        self.stack_size_mgr.inc(1);
        let e1 = self.code_size(out);
        self.patch_index(out, goto_end1, e1);
        self.patch_index(out, goto_end2, e1);
    }

    fn visit_and_expr(&mut self, left: &Expr, right: &Expr, out: &mut Program) {
        self.visit_expr(left, out);
        self.emit_op(out, Opcode::If);
        self.stack_size_mgr.dec(1);
        let first_if_pos = self.emit_placeholder(out);
        self.visit_expr(right, out);
        self.emit_op(out, Opcode::If);
        self.stack_size_mgr.dec(1);
        let second_if_pos = self.emit_placeholder(out);
        let depth_at_if_target = self.stack_size_mgr.size; // 两侧都为真才落到这里
        self.emit_op(out, Opcode::PushTrue);
        self.stack_size_mgr.inc(1);
        self.emit_op(out, Opcode::GoTo);
        let goto_end = self.emit_placeholder(out);
        self.patch_index(out, first_if_pos, self.code_size(out));
        self.patch_index(out, second_if_pos, self.code_size(out));
        self.stack_size_mgr.converge(depth_at_if_target);
        self.emit_op(out, Opcode::PushFalse);
        self.stack_size_mgr.inc(1);
        let e = self.code_size(out);
        self.patch_index(out, goto_end, e);
    }

    // ---------------- 小工具 ----------------

    /// 标识符 → 变量槽位索引。没声明过就当作外部变量，登记到文件作用域。
    fn ident_slot(&mut self, out: &mut Program, name: &str) -> i32 {
        if let Some(host) = self.find_ident_host(name) {
            return self.scope_stack[host].id_map[name];
        }
        let idx = self.var_alloc.new_unique_var(name);
        self.declare_exported(out, name, idx);
        self.file_scope().id_map[name]
    }

    /// 登记一个会进 `Program.exports` 的变量（索引来自 `new_unique_var`，不回收）。
    fn declare_exported(&mut self, out: &mut Program, name: &str, idx: i32) {
        self.file_scope().id_map.insert(name.to_string(), idx);
        out.exports.insert(name.to_string(), idx);
    }

    /// 块 / if 分支 / 循环体在 AST 里都是裸 `Prog`（没有 BlockStmt 包着），
    /// 这里补一层 BlockScope，让内部 let 的变量在离开时被回收。
    fn visit_body_as_block(&mut self, p: &Prog, out: &mut Program) {
        self.push_block_scope();
        self.visit_prog(p, out);
        let idxs: Vec<i32> = self.scope_stack.last().unwrap().id_map.values().copied().collect();
        self.pop_scope();
        for idx in idxs {
            self.var_alloc.free_var(idx);
        }
    }
}

/// 二元运算符 → 指令。注意二元 `-` 是 `Sub` 而不是 `Minus`。
fn binary_opcode(op: TokenType) -> Opcode {
    match op {
        TokenType::EQ => Opcode::EQ,
        TokenType::NE => Opcode::NE,
        TokenType::LT => Opcode::LT,
        TokenType::LE => Opcode::LE,
        TokenType::GT => Opcode::GT,
        TokenType::GE => Opcode::GE,
        TokenType::Add => Opcode::Add,
        TokenType::Sub => Opcode::Sub,
        TokenType::Mul => Opcode::Mul,
        TokenType::Div => Opcode::Div,
        TokenType::IDiv => Opcode::IDiv,
        TokenType::Mod => Opcode::Mod,
        TokenType::Pow => Opcode::Pow,
        _ => Opcode::Pop, // 到不了：parser 只会用上面这些 op 构造 BinaryOpExpr
    }
}
