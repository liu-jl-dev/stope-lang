//! 参考执行器 —— 对齐 `python/stope/basic_vm.py` / `cpp/include/stope/basic_vm.hpp`。
//!
//! **这不是标准。** 值模型（对应 C++ 的 `Value::Type`）：
//!
//! * [`Value::Null`] / [`Value::Int`]（语义 int64，溢出回绕）/ [`Value::Float`] /
//!   [`Value::Str`]（UTF-16 码元）/ [`Value::BinArr`] / [`Value::Identifier`]
//!   （`PushId` 压的槽位引用，只有 `Assign` 认它）/ [`Value::HostFunction`]。
//! * C++ 里**没有 Bool 值类型**：`PushTrue` / `PushFalse` 压的是 Integer 1 / 0，
//!   所以 `true == 1` 在运行期为真。
//!
//! `step()` 与 `run()` 是**两份独立实现**（热循环里不套函数调用），
//! 由 `tests/vm.rs` 的 V-21 锁住两条路径一致。

use crate::common::{int_div, int_mod, int_pow};
use crate::program::Program;
use std::rc::Rc;

/// 宿主函数：参数整包进来，返回一个值（Stope 没有布尔类型，宿主想返回真就给
/// `Value::Int(1)`）。
pub type HostFn = Rc<dyn Fn(&mut State, &[Value]) -> Value>;

/// 运行期值。
#[derive(Clone)]
pub enum Value {
    Null,
    Int(i64),
    Float(f64),
    /// UTF-16 码元序列（下标 / 长度 / 切片都按码元，不是 char、不是字节）
    Str(Rc<Vec<u16>>),
    BinArr(Rc<Vec<u8>>),
    HostFunction(HostFn),
    /// 槽位引用。`PushId` 压它（左值），`Assign` 靠它取槽位；其余指令当普通值。
    Identifier(usize),
}

impl Value {
    pub fn str_from_utf8(s: &str) -> Value {
        Value::Str(Rc::new(s.encode_utf16().collect()))
    }

    pub fn utf8(&self) -> Option<String> {
        match self {
            Value::Str(u) => String::from_utf16(u).ok(),
            _ => None,
        }
    }
}

impl std::fmt::Debug for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Value::Null => write!(f, "Null"),
            Value::Int(i) => write!(f, "Int({})", i),
            Value::Float(x) => write!(f, "Float({})", x),
            Value::Str(u) => write!(f, "Str({:?})", String::from_utf16_lossy(u)),
            Value::BinArr(b) => write!(f, "BinArr(len={})", b.len()),
            Value::HostFunction(_) => write!(f, "HostFunction"),
            Value::Identifier(i) => write!(f, "Identifier({})", i),
        }
    }
}

// ============================== 类型判定 ==============================

pub fn is_null(v: &Value) -> bool {
    matches!(v, Value::Null)
}

pub fn is_int(v: &Value) -> bool {
    matches!(v, Value::Int(_))
}

pub fn is_float(v: &Value) -> bool {
    matches!(v, Value::Float(_))
}

pub fn is_number(v: &Value) -> bool {
    is_int(v) || is_float(v)
}

pub fn is_string(v: &Value) -> bool {
    matches!(v, Value::Str(_))
}

pub fn is_binarr(v: &Value) -> bool {
    matches!(v, Value::BinArr(_))
}

pub fn is_func(v: &Value) -> bool {
    matches!(v, Value::HostFunction(_))
}

pub fn is_sequence(v: &Value) -> bool {
    is_string(v) || is_binarr(v)
}

pub fn as_double(v: &Value) -> f64 {
    match v {
        Value::Int(i) => *i as f64,
        Value::Float(f) => *f,
        _ => 0.0,
    }
}

// ============================== 真值 / 相等 ==============================

/// null→假；整数→非零；宿主函数→真；浮点→非 0；序列→非空；其余→真。
pub fn truely(val: &Value) -> bool {
    match val {
        Value::Null => false,
        Value::Int(i) => *i != 0,
        Value::Float(f) => *f != 0.0,
        Value::Str(s) => !s.is_empty(),
        Value::BinArr(b) => !b.is_empty(),
        Value::HostFunction(_) => true,
        Value::Identifier(_) => true,
    }
}

/// 类型不同一律不等（五份实现统一在这里自己判，不借宿主的 `==`）。
pub fn equals(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Null, Value::Null) => true,
        (Value::Int(a), Value::Int(b)) => a == b,
        (Value::Int(a), Value::Float(b)) => *a as f64 == *b,
        (Value::Float(a), Value::Int(b)) => *a == *b as f64,
        (Value::Float(a), Value::Float(b)) => a == b,
        (Value::Str(a), Value::Str(b)) => a == b,
        (Value::BinArr(a), Value::BinArr(b)) => a == b,
        (Value::HostFunction(a), Value::HostFunction(b)) => Rc::ptr_eq(a, b),
        _ => false,
    }
}

fn less_than(s: &mut State, left: &Value, right: &Value) -> bool {
    if is_number(left) && is_number(right) {
        return as_double(left) < as_double(right);
    }
    s.error("only on integer or float can be compared. ");
    false
}

fn greater_than(s: &mut State, left: &Value, right: &Value) -> bool {
    less_than(s, right, left)
}

fn check_arith(s: &mut State, op: &str, left: &Value, right: &Value) -> bool {
    if is_null(left) || is_null(right) {
        s.error(&format!("\"{}\" cannot operate on null. ", op));
        return false;
    }
    if !is_number(left) || !is_number(right) {
        s.error(&format!("\"{}\" can only operate on integer or float. ", op));
        return false;
    }
    true
}

/// 整数除以 0 → 报错（不做除法）。判定看**运算走哪条路径**：只有两侧都是整数才是
/// 整数除法；任一侧是 Float 就走 IEEE，不拦（`1.0 / 0` 与 `1 / 0.0` 都得 inf）。
fn check_int_zero(s: &mut State, op: &str, left: &Value, right: &Value) -> bool {
    if is_int(left) && is_int(right) {
        if let (Value::Int(_), Value::Int(r)) = (left, right) {
            if *r == 0 {
                s.error(&format!("\"{}\" division by zero. ", op));
                return false;
            }
        }
    }
    true
}

// ============================== 实参表 ==============================

/// 宿主的实参表。取不到就**自己报错**：`state.error(...)` 之后返回 `Value::Null`
/// —— 错误进同一个 `errors`，执行器立刻停。
pub trait Arguments {
    fn at(&self, state: &mut State, index_or_key: &Value) -> Value;
    fn num(&self) -> i64;
}

// ============================== State ==============================

pub type OpFunc = fn(&mut State);

/// 指令指针 + 变量槽 + 求值栈 + 错误列表。
pub struct State {
    pub api: Option<Rc<Api>>,
    pub program: Option<Rc<Program>>,
    pub args: Option<Rc<dyn Arguments>>,
    pub returns: Vec<Value>,
    /// 指令指针：下标进 `program.opcodes`。用 isize 是因为 GoTo/If 的实现会把 i
    /// 先拨到「目标 - 1」，再由 step/run 的 +1 修正 —— 与五份实现一致。
    pub i: isize,
    pub variables: Vec<Value>,
    pub stack: Vec<Value>,
    pub errors: Vec<String>,
}

impl Default for State {
    fn default() -> Self {
        State::new()
    }
}

impl State {
    pub fn new() -> Self {
        State {
            api: None,
            program: None,
            args: None,
            returns: Vec::new(),
            i: 0,
            variables: Vec::new(),
            stack: Vec::new(),
            errors: Vec::new(),
        }
    }

    /// 三样都要给；同时清 `returns` / `stack` / `errors`，并按 `variable_num`
    /// 开好槽位。
    pub fn reset(&mut self, api: Rc<Api>, program: Rc<Program>, args: Option<Rc<dyn Arguments>>) {
        self.api = Some(api);
        self.program = Some(program);
        self.args = args;
        self.returns = Vec::new();
        self.i = 0;
        self.variables = vec![Value::Null; self.program.as_ref().unwrap().variable_num.max(0) as usize];
        self.stack = Vec::new();
        self.errors = Vec::new();
    }

    pub fn set_arguments(&mut self, args: Rc<dyn Arguments>) {
        self.args = Some(args);
    }

    /// 宿主的报错入口：`"<指令下标>: msg"`。
    pub fn error(&mut self, msg: &str) {
        self.errors.push(format!("{}: {}", self.i, msg));
    }

    pub fn has_error(&self) -> bool {
        !self.errors.is_empty()
    }

    fn ops(&self) -> &[i32] {
        &self.program.as_ref().unwrap().opcodes
    }

    /// 执行**一条**指令。`Result::Success` = 这条跑完了且没出错，可以接着 step。
    ///
    /// 返回 `Error` 有两种情况，靠 `errors` 区分：非空 —— 出错了；为空 —— 指令流
    /// 已经走完。`while s.i < n && s.step() == Success` 与 `run` 等价。
    pub fn step(&mut self) -> crate::common::Result {
        if !self.errors.is_empty() {
            return crate::common::Result::Error;
        }
        if self.i >= self.ops().len() as isize {
            return crate::common::Result::Success;
        }
        let op = self.ops()[self.i as usize];
        let f = self.api.as_ref().unwrap().op_map[op.max(0) as usize];
        f(self);
        if !self.errors.is_empty() {
            return crate::common::Result::Error;
        }
        self.i += 1;
        crate::common::Result::Success
    }

    /// 一直执行到指令流结束；出错立即停。与 [`State::step`] 是**两份独立实现**。
    pub fn run(&mut self) -> crate::common::Result {
        let n = self.ops().len() as isize;
        while self.i < n {
            let op = self.ops()[self.i as usize];
            let f = self.api.as_ref().unwrap().op_map[op.max(0) as usize];
            f(self);
            if !self.errors.is_empty() {
                return crate::common::Result::Error;
            }
            self.i += 1;
        }
        crate::common::Result::Success
    }

    /// 栈顶下标一律「从栈顶数、1 起算」：at_top(1) 就是 stack[-1]。
    pub fn at_top(&self, k: usize) -> &Value {
        &self.stack[self.stack.len() - k]
    }

    pub fn at_top_mut(&mut self, k: usize) -> &mut Value {
        let n = self.stack.len();
        &mut self.stack[n - k]
    }

    pub fn pop(&mut self) {
        self.stack.pop();
    }

    pub fn pop_n(&mut self, num: usize) {
        for _ in 0..num {
            self.stack.pop();
        }
    }

    /// 二元算术统一的收尾：弹出右操作数，结果写回左操作数的位置。
    fn store_binary(&mut self, result: Value) {
        self.stack.pop();
        *self.stack.last_mut().unwrap() = result;
    }
}

/// 指令分派表。`op_map` 的下标就是指令编号，稠密。要跑自定义指令必须自己扩表 ——
/// 用 [`Api::set_opcode`]，它会先把中间补齐。
pub struct Api {
    pub op_map: Vec<OpFunc>,
}

impl Default for Api {
    fn default() -> Self {
        Api::new()
    }
}

impl Api {
    pub fn new() -> Self {
        Api {
            op_map: vec![
                op_assign, op_push_null, op_push_false, op_push_true, op_push_int,
                op_push_float, op_push_string, op_push_binarr, op_push_value, op_push_id,
                op_call, op_at, op_pop, op_minus, op_not,
                op_pow, op_mul, op_div, op_idiv, op_mod,
                op_add, op_sub, op_eq, op_ne, op_lt,
                op_le, op_gt, op_ge, op_if, op_goto,
                op_get_arg, op_arg_num, op_return,
            ],
        }
    }

    /// 装一条自定义指令的处理函数：`fn(state)`。
    pub fn set_opcode(&mut self, opcode: i32, f: OpFunc) {
        while self.op_map.len() <= opcode as usize {
            self.op_map.push(op_unimplemented);
        }
        self.op_map[opcode as usize] = f;
    }
}

// ============================== 指令 ==============================

fn op_assign(s: &mut State) {
    if s.stack.len() < 2 {
        s.error("stack underflow. ");
        return;
    }
    let is_ident = matches!(s.at_top(2), Value::Identifier(_));
    if !is_ident {
        s.error("no implement for value type. ");
        return;
    }
    let idx = match s.at_top(2) {
        Value::Identifier(i) => *i,
        _ => unreachable!(),
    };
    let v = s.at_top(1).clone();
    s.variables[idx] = v;
    s.pop_n(2);
}

fn op_push_null(s: &mut State) {
    s.stack.push(Value::Null);
}

fn op_push_false(s: &mut State) {
    s.stack.push(Value::Int(0));
}

fn op_push_true(s: &mut State) {
    s.stack.push(Value::Int(1));
}

fn op_push_int(s: &mut State) {
    s.i += 1;
    let idx = s.ops()[s.i as usize];
    let v = s.program.as_ref().unwrap().int_consts[idx as usize];
    s.stack.push(Value::Int(v));
}

fn op_push_float(s: &mut State) {
    s.i += 1;
    let idx = s.ops()[s.i as usize];
    let v = s.program.as_ref().unwrap().float_consts[idx as usize];
    s.stack.push(Value::Float(v));
}

fn op_push_string(s: &mut State) {
    s.i += 1;
    let idx = s.ops()[s.i as usize];
    let v = s.program.as_ref().unwrap().string_consts[idx as usize].clone();
    s.stack.push(Value::str_from_utf8(&v));
}

fn op_push_binarr(s: &mut State) {
    s.i += 1;
    let idx = s.ops()[s.i as usize];
    let v = s.program.as_ref().unwrap().binarr_consts[idx as usize].clone();
    s.stack.push(Value::BinArr(Rc::new(v)));
}

fn op_push_value(s: &mut State) {
    s.i += 1;
    let idx = s.ops()[s.i as usize] as usize;
    let v = s.variables[idx].clone(); // 压【值】；要槽位引用请用 PushId
    s.stack.push(v);
}

fn op_push_id(s: &mut State) {
    s.i += 1;
    let idx = s.ops()[s.i as usize] as usize;
    s.stack.push(Value::Identifier(idx)); // 不能是值，否则无法 Assign
}

fn op_call(s: &mut State) {
    // 不检查栈下溢：参数个数在编译期就定了
    s.i += 1;
    let arg_num = s.ops()[s.i as usize] as usize;
    let callee = s.at_top(arg_num + 1).clone();
    if !is_func(&callee) {
        s.error("\"Call\" can only call a function. ");
        return;
    }
    let argv: Vec<Value> = (1..=arg_num).rev().map(|k| s.at_top(k).clone()).collect();
    let f = match &callee {
        Value::HostFunction(f) => f.clone(),
        _ => unreachable!(),
    };
    let out = f(s, &argv);
    s.pop_n(arg_num);
    *s.stack.last_mut().unwrap() = out;
}

fn op_at(s: &mut State) {
    // 不检查栈下溢：key 个数在编译期就定了
    s.i += 1;
    let key_num = s.ops()[s.i as usize];
    if key_num != 1 {
        s.error("no implement for key num != 1. ");
        return;
    }
    let container = s.at_top(2).clone();
    let key = s.at_top(1).clone();
    if !is_int(&key) {
        s.error("index must be integer. ");
        return;
    }
    let index = match &key {
        Value::Int(i) => *i,
        _ => unreachable!(),
    };
    let result: Value;
    if is_binarr(&container) {
        let b = match &container {
            Value::BinArr(b) => b.clone(),
            _ => unreachable!(),
        };
        if index < 0 || index as usize >= b.len() {
            s.error("index out of range. ");
            return;
        }
        result = Value::Int(b[index as usize] as i64);
    } else if is_string(&container) {
        let u = match &container {
            Value::Str(u) => u.clone(),
            _ => unreachable!(),
        };
        // 取的是**码元**（UTF-16），不是单字符子串 —— 与 C++ / C# 一致。
        if index < 0 || index * 2 + 2 > u.len() as i64 {
            s.error("index out of range. ");
            return;
        }
        result = Value::Int(u[index as usize] as i64);
    } else {
        s.error("no implement for container type. ");
        return;
    }
    s.pop_n(key_num as usize + 1);
    s.stack.push(result);
}

fn op_pop(s: &mut State) {
    s.pop();
}

fn op_minus(s: &mut State) {
    let v = s.at_top(1).clone();
    match v {
        Value::Int(i) => *s.at_top_mut(1) = Value::Int(i.wrapping_neg()), // 回绕，不检查溢出
        Value::Float(f) => *s.at_top_mut(1) = Value::Float(-f),
        _ => s.error("\"Minus\" can only operate on integer or float. "),
    }
}

fn op_not(s: &mut State) {
    let v = s.at_top(1).clone();
    match v {
        Value::Null => *s.at_top_mut(1) = Value::Int(1),
        Value::Int(i) => *s.at_top_mut(1) = Value::Int(if i == 0 { 1 } else { 0 }),
        Value::Float(f) => *s.at_top_mut(1) = Value::Int(if f == 0.0 { 1 } else { 0 }),
        _ => s.error("\"Not\" can only operate on integer or float. "),
    }
}

fn op_pow(s: &mut State) {
    let left = s.at_top(2).clone();
    let right = s.at_top(1).clone();
    if !check_arith(s, "Pow", &left, &right) {
        return;
    }
    // 两个整数且指数 >= 0 → 整数结果；负指数（`2 ^ -1`）→ Float(0.5)。
    if let (Value::Int(a), Value::Int(b)) = (&left, &right) {
        if *b >= 0 {
            s.store_binary(Value::Int(int_pow(*a, *b)));
            return;
        }
    }
    let out = crate::common::fpow(as_double(&left), as_double(&right));
    s.store_binary(Value::Float(out));
}

fn op_mul(s: &mut State) {
    let left = s.at_top(2).clone();
    let right = s.at_top(1).clone();
    if is_null(&left) || is_null(&right) {
        s.error("\"Mul\" cannot operate on null. ");
        return;
    }
    if is_number(&left) && is_number(&right) {
        if let (Value::Int(a), Value::Int(b)) = (&left, &right) {
            s.store_binary(Value::Int(a.wrapping_mul(*b))); // 回绕
        } else {
            let out = as_double(&left) * as_double(&right);
            s.store_binary(Value::Float(out));
        }
        return;
    }
    if (is_sequence(&left) && is_int(&right)) || (is_int(&left) && is_sequence(&right)) {
        // 序列重复：`2 * "ab"` 与 `"ab" * 2` 都要成立 —— 取序列那一侧
        let seq_is_left = is_sequence(&left);
        let times = if seq_is_left { int_of(&right) } else { int_of(&left) };
        if times < 0 {
            // C++ 报错；Python 的 bytes * -1 会静默得 b""
            s.error("\"Mul\" cannot repeat a sequence by a negative number. ");
            return;
        }
        let out = if seq_is_left {
            repeat_value(&left, times)
        } else {
            repeat_value(&right, times)
        };
        s.store_binary(out);
        return;
    }
    s.error("\"Mul\" can only operate on numbers, or repeat a string / bin array by an integer. ");
}

fn int_of(v: &Value) -> i64 {
    match v {
        Value::Int(i) => *i,
        _ => 0,
    }
}

fn repeat_value(seq: &Value, times: i64) -> Value {
    match seq {
        Value::Str(u) => {
            let mut out = Vec::with_capacity(u.len() * times.max(0) as usize);
            for _ in 0..times {
                out.extend_from_slice(u);
            }
            Value::Str(Rc::new(out))
        }
        Value::BinArr(b) => {
            let mut out = Vec::with_capacity(b.len() * times.max(0) as usize);
            for _ in 0..times {
                out.extend_from_slice(b);
            }
            Value::BinArr(Rc::new(out))
        }
        _ => Value::Null,
    }
}

fn op_div(s: &mut State) {
    let left = s.at_top(2).clone();
    let right = s.at_top(1).clone();
    if !check_arith(s, "Div", &left, &right) || !check_int_zero(s, "Div", &left, &right) {
        return;
    }
    if let (Value::Int(a), Value::Int(b)) = (&left, &right) {
        // 除不尽 → 浮点数（`7 / 2` 是 Float(3.5)）；整除要用 idiv。
        if int_mod(*a, *b) == 0 {
            s.store_binary(Value::Int(int_div(*a, *b)));
        } else {
            let out = crate::common::fdiv(*a as f64, *b as f64);
            s.store_binary(Value::Float(out));
        }
    } else {
        let out = crate::common::fdiv(as_double(&left), as_double(&right));
        s.store_binary(Value::Float(out));
    }
}

fn op_idiv(s: &mut State) {
    let left = s.at_top(2).clone();
    let right = s.at_top(1).clone();
    if !check_arith(s, "IDiv", &left, &right) || !check_int_zero(s, "IDiv", &left, &right) {
        return;
    }
    if let (Value::Int(a), Value::Int(b)) = (&left, &right) {
        s.store_binary(Value::Int(int_div(*a, *b))); // 向零取整
    } else {
        // 含浮点：仍按数值整除（向零取整），结果保持浮点，不做 float→int 收窄
        let out = crate::common::ftrunc(crate::common::fdiv(as_double(&left), as_double(&right)));
        s.store_binary(Value::Float(out));
    }
}

fn op_mod(s: &mut State) {
    let left = s.at_top(2).clone();
    let right = s.at_top(1).clone();
    if !check_arith(s, "Mod", &left, &right) || !check_int_zero(s, "Mod", &left, &right) {
        return;
    }
    if let (Value::Int(a), Value::Int(b)) = (&left, &right) {
        s.store_binary(Value::Int(int_mod(*a, *b))); // 余数符号跟被除数
    } else {
        // ⚠ 用 fmod 而不是 Python 的 `%`：后者的符号跟除数，与 C++/JS/C# 相反
        let out = crate::common::fmod(as_double(&left), as_double(&right));
        s.store_binary(Value::Float(out));
    }
}

fn op_add(s: &mut State) {
    let left = s.at_top(2).clone();
    let right = s.at_top(1).clone();
    // null 不是「加法单位元」，也不与任何值做算术 —— 一律报错
    if is_null(&left) || is_null(&right) {
        s.error("\"Add\" cannot operate on null. ");
        return;
    }
    if is_int(&left) {
        match &right {
            Value::Int(b) => {
                let a = int_of(&left);
                s.store_binary(Value::Int(a.wrapping_add(*b))); // 回绕
            }
            Value::Float(b) => {
                let a = int_of(&left) as f64;
                s.store_binary(Value::Float(a + b));
            }
            _ => s.error("integer can only add integer or float. "),
        }
    } else if is_float(&left) {
        if is_number(&right) {
            let a = as_double(&left);
            s.store_binary(Value::Float(a + as_double(&right)));
        } else {
            s.error("float can only add integer or float. ");
        }
    } else if is_string(&left) && is_string(&right) {
        let mut u = match &left {
            Value::Str(u) => (**u).clone(),
            _ => unreachable!(),
        };
        if let Value::Str(r) = &right {
            u.extend_from_slice(r);
        }
        s.store_binary(Value::Str(Rc::new(u)));
    } else if is_binarr(&left) && is_binarr(&right) {
        let mut b = match &left {
            Value::BinArr(b) => (**b).clone(),
            _ => unreachable!(),
        };
        if let Value::BinArr(r) = &right {
            b.extend_from_slice(r);
        }
        s.store_binary(Value::BinArr(Rc::new(b)));
    } else {
        s.error("\"Add\" can only operate on numbers, strings or bin arrays. ");
    }
}

fn op_sub(s: &mut State) {
    let left = s.at_top(2).clone();
    let right = s.at_top(1).clone();
    if !check_arith(s, "Sub", &left, &right) {
        return;
    }
    if is_int(&left) {
        match &right {
            Value::Int(b) => {
                let a = int_of(&left);
                s.store_binary(Value::Int(a.wrapping_sub(*b))); // 回绕
            }
            Value::Float(b) => {
                let a = int_of(&left) as f64;
                s.store_binary(Value::Float(a - b));
            }
            _ => s.error("integer can only subtract integer or float. "),
        }
    } else if is_float(&left) {
        if is_number(&right) {
            let a = as_double(&left);
            s.store_binary(Value::Float(a - as_double(&right)));
        } else {
            s.error("float can only subtract integer or float. ");
        }
    } else {
        s.error("\"Sub\" can only operate on integer or float. ");
    }
}

fn op_eq(s: &mut State) {
    let out = equals(s.at_top(2), s.at_top(1));
    s.store_binary(Value::Int(if out { 1 } else { 0 }));
}

fn op_ne(s: &mut State) {
    let out = equals(s.at_top(2), s.at_top(1));
    s.store_binary(Value::Int(if out { 0 } else { 1 }));
}

fn op_lt(s: &mut State) {
    let (l, r) = (s.at_top(2).clone(), s.at_top(1).clone());
    let out = less_than(s, &l, &r);
    s.store_binary(Value::Int(if out { 1 } else { 0 }));
}

fn op_le(s: &mut State) {
    let (l, r) = (s.at_top(2).clone(), s.at_top(1).clone());
    let out = greater_than(s, &l, &r);
    s.store_binary(Value::Int(if out { 0 } else { 1 }));
}

fn op_gt(s: &mut State) {
    let (l, r) = (s.at_top(2).clone(), s.at_top(1).clone());
    let out = greater_than(s, &l, &r);
    s.store_binary(Value::Int(if out { 1 } else { 0 }));
}

fn op_ge(s: &mut State) {
    let (l, r) = (s.at_top(2).clone(), s.at_top(1).clone());
    let out = less_than(s, &l, &r);
    s.store_binary(Value::Int(if out { 0 } else { 1 }));
}

fn op_if(s: &mut State) {
    let yes = truely(s.stack.last().unwrap());
    s.pop(); // 条件用完即弹，不再留在栈上
    s.i += 1; // 跳过操作数；条件成立时 step/run 的 +1 正好落到下一句
    let target = s.ops()[s.i as usize];
    if !yes {
        s.i = target as isize - 1;
    }
}

fn op_goto(s: &mut State) {
    let target = s.ops()[s.i as usize + 1]; // 操作数在 i+1
    s.i = target as isize - 1;
}

fn op_get_arg(s: &mut State) {
    if s.args.is_none() {
        s.error("no args. ");
        return;
    }
    // 先弹 key 再取参：实参表可能拿 key 做准备
    let key = s.stack.pop().unwrap(); // 栈上一定是值：读变量走 PushValue
    let args = s.args.as_ref().unwrap().clone();
    let out = args.at(s, &key);
    s.stack.push(out);
}

fn op_arg_num(s: &mut State) {
    if s.args.is_none() {
        s.error("no args. ");
        return;
    }
    let n = s.args.as_ref().unwrap().num();
    s.stack.push(Value::Int(n));
}

fn op_return(s: &mut State) {
    s.i += 1;
    let num = s.ops()[s.i as usize] as usize;
    s.returns = (1..=num).rev().map(|k| s.at_top(k).clone()).collect();
    s.i = s.ops().len() as isize;
}

/// 占位处理函数：指令表被 `set_opcode` 撑出来但那一格没注册。
fn op_unimplemented(s: &mut State) {
    let op = s.ops()[s.i as usize];
    s.error(&format!("no implement for opcode {}. ", op));
}
