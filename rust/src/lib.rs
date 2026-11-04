//! Stope 语言的 Rust 实现。
//!
//! 分层与另外五套实现一一对应：
//!
//! **标准层**（语言、STML、编译产物 `Program`）
//! [`Lexer`](lexer::Lexer) / [`Parser`](parser::Parser) / [`ast`](ast) /
//! [`optimize`](expr_optim::optimize) / [`Compiler`](compiler::Compiler) /
//! [`Program`](program::Program) / [`BinaryArrayParser`](binarr::parse_binary_array) /
//! [`disasm`](disasm) / STML 三件套（[`stml`]）。
//!
//! **示例层**：[`basic_vm`]（`Api` / `State` / `Arguments`）—— **不是标准**。
//!
//! 「标准」的含义见仓库根 README：Stope 只规定语言、STML 与编译产物 `Program`；
//! 虚拟机只是参考实现。

pub mod ast;
pub mod basic_vm;
pub mod binarr;
pub mod common;
pub mod compiler;
pub mod disasm;
pub mod expr_optim;
pub mod lexer;
pub mod opcode;
pub mod parser;
pub mod program;
pub mod stml;
pub mod token;
pub mod utf;

pub use ast::{Prog, Stmt, Expr};
pub use basic_vm::{Api, Arguments, State, Value};
pub use common::Result;
pub use compiler::Compiler;
pub use disasm::{custom_opcode_has_arg, disasm, disasm_no_custom, opcode_has_arg};
pub use expr_optim::optimize;
pub use lexer::Lexer;
pub use opcode::{CustomOpcode, CustomOpcodeConfig, Opcode, K_FIRST_CUSTOM_OPCODE};
pub use parser::Parser;
pub use program::Program;
pub use stml::lexer as stml_lexer;
pub use stml::parser as stml_parser;
pub use stml::{Element as StmlElement, LexerState as StmlState, Token as StmlToken, TokenType as StmlTokenType};
pub use token::{Token, TokenType, type_name};
pub use utf::{esc, fmt_bytes, fmt_g};
