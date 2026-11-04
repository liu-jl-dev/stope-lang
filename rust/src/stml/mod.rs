//! STML 的公共类型：元素与 Token —— 对齐 `python/stope/stml.py`。

pub mod lexer;
pub mod parser;

use std::collections::BTreeMap;

/// 12 项，与 C++ 的 `STML::TokenType` 值和名字都一样（顺序不能改）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TokenType {
    Invalid = 0,
    Eof = 1,
    LAngle = 2,    // <
    RAngle = 3,    // >
    CLAngle = 4,   // </>
    CRAngle = 5,   // />
    EQ = 6,        // =
    Word = 7,      // ^[a-zA-Z_:][a-zA-Z0-9_:-]*$（不含 '.'）
    String = 8,    // "" '' —— Xml 属性串，不转义
    Text = 9,      // 元素内普通文本
    NevextSrc = 10, // Nevext 代码
    StopeSrc = 11, // Stope 代码
}

/// 下标即编号，与枚举逐项对应（打印类型名用 [`type_name`]）。
pub const TOKEN_TYPE_NAMES: [&str; 12] = [
    "Invalid", "Eof", "LAngle", "RAngle", "CLAngle", "CRAngle",
    "EQ", "Word", "String", "Text", "NevextSrc", "StopeSrc",
];

pub fn type_name(t: TokenType) -> &'static str {
    TOKEN_TYPE_NAMES[t as usize]
}

/// 词法四态。扫完一段 Text / Nevext / Stope 后**必须交还 Xml**。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LexerState {
    Xml = 0,
    Text = 1,
    Nevext = 2,
    Stope = 3,
}

/// 一个词法单元。`lexeme` 是输入的子串（复制）。
#[derive(Debug, Clone)]
pub struct Token {
    pub type_: TokenType,
    pub line: i32,
    pub lexeme: String,
}

impl Default for Token {
    fn default() -> Self {
        Token { type_: TokenType::Invalid, line: -1, lexeme: String::new() }
    }
}

impl Token {
    pub fn set(&mut self, t: TokenType, lexeme: &str) {
        self.type_ = t;
        self.lexeme = lexeme.to_string();
    }
}

/// 一个元素。`children` 与 `text` 互斥；`text` 只有一段，不拼接。
///
/// `attrs` 用 `BTreeMap`：golden 的形状串按**键字典序**输出（C++ 是 `std::map`），
/// 同名属性保留**先出现的**（`std::map::emplace` 语义）。
#[derive(Debug, Clone, Default)]
pub struct Element {
    pub line: i32,
    /// text / 代码段第一个字符的物理行号；元素没有内容时为 -1。
    pub text_line: i32,
    pub tag: String,
    pub attrs: BTreeMap<String, String>,
    pub self_closing: bool,
    pub children: Vec<Element>,
    pub text: String,
}

impl Element {
    pub fn new() -> Self {
        Element {
            line: -1,
            text_line: -1,
            tag: String::new(),
            attrs: BTreeMap::new(),
            self_closing: false,
            children: Vec::new(),
            text: String::new(),
        }
    }

    /// 调试用：不一定与源文本逐字符相同（属性顺序、自闭合写法都不保留）。
    pub fn to_str(&self, level: usize) -> String {
        let sp = "  ".repeat(level);
        let mut out = format!("{}<{}", sp, self.tag);
        for (name, value) in &self.attrs {
            out += " ";
            out += name;
            if !value.is_empty() {
                out += &format!("=\"{}\"", value);
            }
        }
        if self.self_closing {
            out += " />\n";
        } else {
            out += ">\n";
            out += &self.text;
            for c in &self.children {
                out += &c.to_str(level + 1);
            }
            out += &format!("{}</{}>\n", sp, self.tag);
        }
        out
    }
}
