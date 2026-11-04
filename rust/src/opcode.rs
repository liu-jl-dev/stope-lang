//! 指令集与自定义指令登记表 —— 对齐 `python/stope/opcode.py`。
//!
//! 33 条内置指令（0..32），编号与 C++ 的 `stope::Opcode` 逐项相同。自定义指令从
//! 33 起。Lexer / Parser / Compiler **必须共用同一个** [`CustomOpcodeConfig`]。

/// 指令编号（与 C++ 逐项相同）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Opcode {
    Assign = 0,
    PushNull = 1,
    PushFalse = 2,
    PushTrue = 3,
    PushInt = 4,
    PushFloat = 5,
    PushString = 6,
    PushBinArr = 7,
    PushValue = 8,
    PushId = 9,
    Call = 10,
    At = 11,
    Pop = 12,
    Minus = 13,
    Not = 14,
    Pow = 15,
    Mul = 16,
    Div = 17,
    IDiv = 18,
    Mod = 19,
    Add = 20,
    Sub = 21,
    EQ = 22,
    NE = 23,
    LT = 24,
    LE = 25,
    GT = 26,
    GE = 27,
    If = 28,
    GoTo = 29,
    GetArg = 30,
    ArgNum = 31,
    Return = 32,
}

/// 第一个可用的自定义指令编号（= Return + 1）。
pub const K_FIRST_CUSTOM_OPCODE: i32 = Opcode::Return as i32 + 1;

/// 一条自定义指令的登记项。`arg_num < 0` 表示变长（产物里不带参数）；定长时产物
/// 紧跟一个操作数（参数个数）。
#[derive(Debug, Clone, Copy)]
pub struct CustomOpcode {
    pub opcode: i32,
    pub arg_num: i32,
    pub is_var_arg: bool,
}

/// 名字 → `CustomOpcode` 的登记表。名字是普通标识符或命名空间形式 `a:b`
/// （词法器保证），且**关键字优先**。
#[derive(Debug, Default)]
pub struct CustomOpcodeConfig {
    /// 保持登记顺序；查找走 `find`。dump 时显式按名字排序。
    pub opcodes: Vec<(String, CustomOpcode)>,
}

impl CustomOpcodeConfig {
    pub fn new() -> Self {
        CustomOpcodeConfig { opcodes: Vec::new() }
    }

    /// 登记一条自定义指令；同名重复返回 `DuplicateWithBuiltinOpcode` 且不插入。
    pub fn add_custom_opcode(&mut self, name: &str, opcode: i32, arg_num: i32) -> crate::common::Result {
        if self.find(name).is_some() {
            return crate::common::Result::DuplicateWithBuiltinOpcode;
        }
        self.opcodes.push((
            name.to_string(),
            CustomOpcode { opcode, arg_num, is_var_arg: arg_num < 0 },
        ));
        crate::common::Result::Success
    }

    pub fn find(&self, name: &str) -> Option<&CustomOpcode> {
        self.opcodes.iter().find(|(n, _)| n == name).map(|(_, c)| c)
    }
}

/// 内置指令名（反汇编 / 错误信息用；下标即编号）。
pub const BUILTIN_NAMES: [&str; 33] = [
    "Assign", "PushNull", "PushFalse", "PushTrue", "PushInt",
    "PushFloat", "PushString", "PushBinArr", "PushValue", "PushId",
    "Call", "At", "Pop", "Minus", "Not",
    "Pow", "Mul", "Div", "IDiv", "Mod",
    "Add", "Sub", "EQ", "NE", "LT",
    "LE", "GT", "GE", "If", "GoTo",
    "GetArg", "ArgNum", "Return",
];

pub const BUILTIN_COUNT: i32 = BUILTIN_NAMES.len() as i32;
