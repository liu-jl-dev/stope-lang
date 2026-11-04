//! STML 词法器。四态状态机（Xml / Text / Nevext / Stope）—— 对齐
//! `python/stope/stml_lexer.py` / `cpp/src/stml_lexer.cpp`。
//!
//! 三条最容易写错的规则：
//!
//! 1. Text / Nevext / Stope 扫完一段后**必须把 state 交还 Xml**；
//! 2. 输入耗尽后**永远**返回 `Eof`，与当前状态无关 —— 而且此时**不改 state**；
//! 3. 任何异常路径都要**消费字符**，否则调用方的 while 会死循环。
//!
//! `<sto>` 段里的 Stope 代码在这里**只当作一段文本**跳过（引号串与注释整段吞掉）。

use super::{LexerState, Token, TokenType};

const WHITE: &[char] = &[' ', '\t', '\u{0b}', '\u{0c}', '\r', '\n'];

/// 只有这几类 token 的 lexeme 是「双方实现都提供」的；标点与 Eof 的 lexeme 属实现
/// 自定，不断言。
pub const HAS_LEXEME: [TokenType; 5] = [
    TokenType::Word,
    TokenType::String,
    TokenType::Text,
    TokenType::NevextSrc,
    TokenType::StopeSrc,
];

fn is_alpha(ch: char) -> bool {
    ch.is_ascii_alphabetic()
}

fn is_digit(ch: char) -> bool {
    ch.is_ascii_digit()
}

fn is_word_begin(ch: char) -> bool {
    is_alpha(ch) || ch == '_' || ch == ':'
}

fn is_word_char(ch: char) -> bool {
    is_word_begin(ch) || is_digit(ch) || ch == '-'
}

/// 去掉尾部空白（B-8：内容段尾部的空白不计入 lexeme）。
pub fn trim_trailing_ws(s: &str) -> &str {
    s.trim_end_matches(WHITE)
}

/// 按需产出 token。`errors` 累积词法错误（与语法错误分开报）。
pub struct Lexer {
    pub state: LexerState,
    src: String,
    pos: usize,
    pub line: i32,
    pub errors: Vec<String>,
}

impl Lexer {
    pub fn new(source: &str) -> Self {
        Lexer::with_state(source, LexerState::Xml)
    }

    pub fn with_state(source: &str, state: LexerState) -> Self {
        Lexer {
            state,
            src: source.to_string(),
            pos: 0,
            line: 1,
            errors: Vec::new(),
        }
    }

    fn rest(&self) -> &str {
        &self.src[self.pos..]
    }

    fn starts_with(&self, prefix: &str) -> bool {
        self.rest().starts_with(prefix)
    }

    fn eof(&self) -> bool {
        self.pos >= self.src.len()
    }

    pub fn next_token(&mut self) -> Token {
        let mut token = Token::default();
        self.skip_ws();
        token.line = self.line;
        if self.eof() {
            token.type_ = TokenType::Eof;
        } else if self.state == LexerState::Xml {
            if self.starts_with("</") {
                token.set(TokenType::CLAngle, "</");
                self.pos += 2;
            } else if self.starts_with("/>") {
                token.set(TokenType::CRAngle, "/>");
                self.pos += 2;
            } else if self.rest().starts_with('<') {
                token.set(TokenType::LAngle, "<");
                self.pos += 1;
            } else if self.rest().starts_with('>') {
                token.set(TokenType::RAngle, ">");
                self.pos += 1;
            } else if self.rest().starts_with('=') {
                token.set(TokenType::EQ, "=");
                self.pos += 1;
            } else if self.rest().starts_with('"') || self.rest().starts_with('\'') {
                self.scan_string(&mut token);
            } else if is_word_begin(self.rest().chars().next().unwrap()) {
                let w = self.scan_word();
                token.set(TokenType::Word, &w);
            } else {
                self.error("unexpected character. ");
                token.set(TokenType::Invalid, "");
                self.pos += self.rest().chars().next().unwrap().len_utf8(); // 必须消费，否则死循环
            }
        } else if self.state == LexerState::Text {
            let t = self.scan_content(false);
            token.set(TokenType::Text, &t);
            self.state = LexerState::Xml;
        } else if self.state == LexerState::Nevext {
            let t = self.scan_content(true);
            token.set(TokenType::NevextSrc, &t);
            self.state = LexerState::Xml;
        } else {
            // LexerState::Stope
            let t = self.scan_content(true);
            token.set(TokenType::StopeSrc, &t);
            self.state = LexerState::Xml;
        }
        token
    }

    // ============================ Xml 状态 ============================

    /// Xml 属性串：**不转义**（`\"` 里的引号就是结束引号，TD-9）。
    /// 未闭合时报错（文案比代码段那条**少一个句号**，TD-8）并吃掉剩余全部输入。
    fn scan_string(&mut self, token: &mut Token) {
        token.type_ = TokenType::String;
        let quote = self.rest().chars().next().unwrap();
        self.pos += 1; // 跳过开头的引号
        let rest = self.rest().to_string();
        let mut n = 0usize; // 字节偏移
        for ch in rest.chars() {
            if ch == quote {
                token.lexeme = rest[..n].to_string();
                self.pos += n + 1;
                return;
            }
            if ch == '\n' {
                self.line += 1;
            }
            n += ch.len_utf8();
        }
        self.error("unclosed string literal");
        self.pos = self.src.len();
        token.type_ = TokenType::Invalid;
    }

    fn scan_word(&mut self) -> String {
        let rest = self.rest();
        let mut end = rest.chars().next().unwrap().len_utf8();
        for ch in rest[end..].chars() {
            if !is_word_char(ch) {
                break;
            }
            end += ch.len_utf8();
        }
        let s = rest[..end].to_string();
        self.pos += end;
        s
    }

    // ============================ 内容三态 ============================

    /// Text / Nevext / Stope 三个扫描函数同构：从当前位置一路吃到 `</` 或输入耗尽，
    /// 尾部空白不计入 lexeme（B-8）。`text` 只认 `</`；两个代码段还把引号串与注释
    /// 整段跳过，其中的 `</` 不算结束标签（B-3）。
    fn scan_content(&mut self, code_mode: bool) -> String {
        let begin_pos = self.pos;
        while !self.eof() {
            if self.starts_with("</") {
                break;
            }
            if code_mode {
                let ch = self.rest().chars().next().unwrap();
                if ch == '\'' || ch == '"' {
                    // Nevext：两种引号都转义；Stope：双引号转义、单引号（BinArr）不转义
                    self.scan_code_str(ch, code_mode || ch == '"');
                    continue;
                }
                if self.starts_with("//") {
                    self.skip_singleline_comment();
                    continue;
                }
                if self.starts_with("/*") {
                    self.skip_multiline_comment();
                    continue;
                }
            }
            if self.rest().starts_with('\n') {
                self.line += 1;
            }
            self.pos += self.rest().chars().next().unwrap().len_utf8();
        }
        let raw = &self.src[begin_pos..self.pos];
        trim_trailing_ws(raw).to_string()
    }

    /// 代码段里的引号串，含两侧引号。到输入末尾仍未闭合时报错并**吃掉剩余全部输入**；
    /// 报的是**起始行**，不是当前行。
    fn scan_code_str(&mut self, quote: char, escapes: bool) {
        let begin_line = self.line;
        self.pos += quote.len_utf8(); // 跳过开头的引号
        while !self.eof() {
            let c = self.rest().chars().next().unwrap();
            self.pos += c.len_utf8();
            if escapes && c == '\\' {
                // 转义：连同紧跟的一个字符一起吃掉
                if self.eof() {
                    self.error_at(begin_line, "unclosed string literal. ");
                    return;
                }
                if self.rest().starts_with('\n') {
                    self.line += 1;
                }
                let n = self.rest().chars().next().unwrap().len_utf8();
                self.pos += n;
            } else if c == quote {
                return;
            } else if c == '\n' {
                self.line += 1;
            }
        }
        self.error_at(begin_line, "unclosed string literal. ");
    }

    /// `//` 到行尾；换行符一并消费并推进行号。
    fn skip_singleline_comment(&mut self) {
        self.pos += 2;
        while !self.eof() {
            let c = self.rest().chars().next().unwrap();
            self.pos += c.len_utf8();
            if c == '\n' {
                self.line += 1;
                return;
            }
        }
    }

    /// `/*` 到 `*/`。未闭合**不是错误**，一直吃到输入末尾。
    fn skip_multiline_comment(&mut self) {
        self.pos += 2;
        while !self.eof() {
            if self.starts_with("*/") {
                self.pos += 2;
                return;
            }
            if self.rest().starts_with('\n') {
                self.line += 1;
            }
            self.pos += self.rest().chars().next().unwrap().len_utf8();
        }
    }

    // ============================ 空白与注释 ============================

    fn skip_ws(&mut self) {
        while !self.eof() {
            let ch = self.rest().chars().next().unwrap();
            if WHITE.contains(&ch) {
                if ch == '\n' {
                    self.line += 1;
                }
                self.pos += ch.len_utf8();
            } else if self.state == LexerState::Xml && self.starts_with("<!--") {
                // `<!--` 只在 Xml 状态是注释；Nevext / Stope 里的 '<' 是小于号
                self.skip_xml_comment();
            } else {
                break;
            }
        }
    }

    fn skip_xml_comment(&mut self) {
        self.pos += 4;
        while !self.eof() {
            if self.starts_with("-->") {
                self.pos += 3;
                return;
            }
            if self.rest().starts_with('\n') {
                self.line += 1;
            }
            self.pos += self.rest().chars().next().unwrap().len_utf8();
        }
    }

    // ============================ 报错 ============================

    fn error(&mut self, msg: &str) {
        self.errors.push(format!("line {}: {}", self.line, msg));
    }

    /// 指定行号报错：跨行的字面量 / 注释报的是**起始行**，不是当前行。
    fn error_at(&mut self, line: i32, msg: &str) {
        self.errors.push(format!("line {}: {}", line, msg));
    }
}
