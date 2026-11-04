//! STML 语法分析器 —— 对齐 `python/stope/stml_parser.py` / `cpp/src/stml_parser.cpp`。
//!
//! STML 比 XML 更严格：
//!
//! * 没有字符实体；
//! * 属性可以没有值：`<a flag>` 等价于 `flag = ""`（因此属性循环**不能**在开头无条件
//!   `next_token()`，否则无值属性会多吞一个 token）；
//! * 子元素与元素内文本互斥；元素内文本只有一段，由词法器一次性给出。
//!
//! 宿主回调 `state_func(tag, attrs) -> LexerState` 决定元素内容怎么扫。

use super::lexer::Lexer;
use super::{Element, LexerState, TokenType};
use crate::common::Result as StopeResult;
use std::collections::BTreeMap;

pub type StateFunc<'a> = dyn Fn(&str, &BTreeMap<String, String>) -> LexerState + 'a;

/// 默认回调：`<sto>` → Stope、`<nev>` → Nevext、`<p>` → Text，其余 Xml。
pub fn default_state_func(tag: &str, _attrs: &BTreeMap<String, String>) -> LexerState {
    match tag {
        "sto" => LexerState::Stope,
        "nev" => LexerState::Nevext,
        "p" => LexerState::Text,
        _ => LexerState::Xml,
    }
}

pub enum StateFuncOpt<'a> {
    None,
    Default,
    Custom(Box<StateFunc<'a>>),
}

pub struct Parser<'a> {
    lexer: &'a mut Lexer,
    state_func: StateFuncOpt<'a>,
    pub errors: Vec<String>,
    token: super::Token,
    /// 元素嵌套深度上限（根元素算第 1 层），0 = 不限。
    pub max_depth: i32,
    aborted: bool,
}

impl<'a> Parser<'a> {
    pub fn new(lexer: &'a mut Lexer) -> Self {
        Parser {
            lexer,
            state_func: StateFuncOpt::Default,
            errors: Vec::new(),
            token: Default::default(),
            max_depth: 256,
            aborted: false,
        }
    }

    /// 词法器只读访问（errors 等）。
    pub fn lexer(&self) -> &Lexer {
        self.lexer
    }

    pub fn parse(&mut self, root: &mut Element, state_func: StateFuncOpt<'a>) -> StopeResult {
        self.state_func = state_func;
        self.aborted = false;
        self.next_token();
        self.parse_element(root, 1); // 根元素算第 1 层
        if self.errors.is_empty() {
            StopeResult::Success
        } else {
            StopeResult::Error
        }
    }

    fn parse_element(&mut self, e: &mut Element, depth: i32) {
        // 深度检查：唯一递归点在子元素分支，检查放入口即可。aborted 之后逐层
        // 提前 return，不再消费任何 token —— 超限只报一条错。
        if self.aborted {
            return;
        }
        if self.max_depth > 0 && depth > self.max_depth {
            self.abort_too_deep();
            return;
        }
        // 进入元素一律先回到 Xml 状态：自闭合分支与出错提前返回的路径都走不到下面的
        // state_func，留着上一次的 Text / Nevext / Stope 会污染后续 token
        self.lexer.state = LexerState::Xml;
        e.line = self.token.line;
        if self.token.type_ != TokenType::LAngle {
            self.error("expected \"<\". ");
            return;
        }
        self.next_token();
        if self.token.type_ != TokenType::Word {
            self.error("expected tag name. ");
            return;
        }
        e.tag = self.token.lexeme.clone();
        self.next_token(); // 第一个属性名，或 > 或 />
        // 每个分支自己负责推进到下一个待判断的 token。
        // 不能写成「循环开头 next_token」，否则无值属性的向前看会多吞一个 token。
        loop {
            // (word ("=" string)?)*
            if self.token.type_ == TokenType::RAngle {
                break;
            }
            if self.token.type_ == TokenType::CRAngle {
                e.self_closing = true;
                return;
            }
            if self.token.type_ == TokenType::Word {
                let name = self.token.lexeme.clone();
                self.next_token();
                if self.token.type_ == TokenType::EQ {
                    self.next_token();
                    if self.token.type_ != TokenType::String {
                        self.error("expected string. ");
                        return;
                    }
                    // 同名属性保留**先出现的**那个（C++ 的 std::map::emplace）
                    e.attrs.entry(name).or_insert_with(|| self.token.lexeme.clone());
                    self.next_token();
                } else {
                    // 无值属性：<a flag> 等价于 attrs["flag"] = ""
                    // 此时 token 已经是下一个属性名 / > 或 />，不能再推进
                    e.attrs.entry(name).or_insert_with(String::new);
                }
            } else {
                self.error("expected \">\" or \"/>\" or attribute. ");
                return;
            }
        }
        // 此时 e.self_closing 为 false，且停在 ">"
        self.lexer.state = match &self.state_func {
            StateFuncOpt::None => LexerState::Xml,
            StateFuncOpt::Default => default_state_func(&e.tag, &e.attrs),
            StateFuncOpt::Custom(f) => f(&e.tag, &e.attrs),
        };

        if self.lexer.state == LexerState::Xml {
            // 递归解析子元素
            loop {
                self.next_token();
                if self.token.type_ == TokenType::CLAngle {
                    // </>
                    break;
                }
                if self.token.type_ == TokenType::LAngle {
                    // < 子元素
                    let mut child = Element::new();
                    self.parse_element(&mut child, depth + 1);
                    e.children.push(child);
                    if self.aborted {
                        return; // 超限的那层已报过错，逐层直接返回，不级联
                    }
                } else {
                    self.error("expected \"<\" or \"</\". ");
                    return;
                }
            }
        } else {
            // Text / Nevext / Stope：整段内容由词法器一次性给出
            self.next_token(); // 词法器保证只会结束在 </ ，不会结束在 <
            if !matches!(
                self.token.type_,
                TokenType::Text | TokenType::NevextSrc | TokenType::StopeSrc
            ) {
                self.error("expected element content. ");
                return;
            }
            e.text = self.token.lexeme.clone(); // 只有一段，不拼接
            e.text_line = self.token.line; // 词法器已跳过前导空白，这是内容的首行（PL-05）
            self.next_token(); // 停在 CLAngle，与上面 Xml 分支的 break 处汇合
        }

        self.next_token(); // 结束标签名
        if self.token.type_ != TokenType::Word {
            self.error("expected tag name. ");
            return;
        }
        if self.token.lexeme != e.tag {
            self.error("tag name mismatch. ");
            return;
        }
        self.next_token();
        if self.token.type_ != TokenType::RAngle {
            self.error("expected \">\". ");
        }
    }

    fn next_token(&mut self) {
        self.token = self.lexer.next_token();
    }

    fn abort_too_deep(&mut self) {
        // 必须在置位之前记账
        let msg = format!("nesting too deep (max {}). ", self.max_depth);
        self.error(&msg);
        self.aborted = true;
    }

    fn error(&mut self, msg: &str) {
        // 超限中止之后的错误都是连锁反应，不再记账 —— 与 Stope 的 Parser 同款
        if self.aborted {
            return;
        }
        self.errors.push(format!("line {}: {}", self.token.line, msg));
    }
}
