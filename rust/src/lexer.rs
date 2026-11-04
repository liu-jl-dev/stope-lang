//! 词法分析器 —— 对齐 `python/stope/lexer.py` / `cpp/src/lexer.cpp`。
//!
//! 同样的错误文案、同样的错误恢复（报错后**继续**产 token，不中断）。源码是
//! UTF-8 `str`，按字节区间切片、按字符扫描；lexeme / parsed 都取值（String），
//! 避免生命周期传染。

use crate::opcode::CustomOpcodeConfig;
use crate::token::{Literal, Token, TokenType};

const INT64_MAX: i64 = i64::MAX;

fn is_white(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\r' | b'\n' | 0x0b | 0x0c)
}

fn is_digit(c: u8) -> bool {
    c.is_ascii_digit()
}

fn is_alpha(c: u8) -> bool {
    c.is_ascii_alphabetic()
}

fn is_ident_begin(c: u8) -> bool {
    is_alpha(c) || c == b'_'
}

fn escape_char(c: u8) -> Option<char> {
    match c {
        b'\\' => Some('\\'),
        b'\'' => Some('\''),
        b'"' => Some('"'),
        b'b' => Some('\u{8}'),
        b'r' => Some('\r'),
        b't' => Some('\t'),
        b'v' => Some('\u{0b}'),
        b'n' => Some('\n'),
        b'f' => Some('\u{0c}'),
        _ => None,
    }
}

/// 词法器。`Lexer::new(src)` → 反复调 [`Lexer::next_token`] 直到 `Eof`。
pub struct Lexer {
    src: String,
    pos: usize,
    line: i32,
    pub errors: Vec<String>,
}

impl Lexer {
    pub fn new(input: &str) -> Self {
        Lexer { src: input.to_string(), pos: 0, line: 1, errors: Vec::new() }
    }

    pub fn reset(&mut self, input: &str) {
        self.src = input.to_string();
        self.pos = 0;
        self.line = 1;
        self.errors.clear();
    }

    /// 设起始物理行号 —— 从 STML 切出来的代码段不是从 1 开始（demo04 用）。
    pub fn set_line(&mut self, line: i32) {
        self.line = line;
    }

    pub fn line(&self) -> i32 {
        self.line
    }

    fn rest(&self) -> &str {
        &self.src[self.pos..]
    }

    fn byte_at(&self, off: usize) -> u8 {
        self.src.as_bytes()[self.pos + off]
    }

    fn starts_with(&self, prefix: &str) -> bool {
        self.rest().starts_with(prefix)
    }

    fn eof(&self) -> bool {
        self.pos >= self.src.len()
    }

    fn error(&mut self, msg: &str) {
        self.errors.push(format!("line {}: {}", self.line, msg));
    }

    /// 取下一个 token。`custom` 是自定义指令登记表，可省。
    ///
    /// 不抛异常：出错只往 `errors` 记一条，然后按最长可行前缀产出 `Invalid` 继续。
    pub fn next_token(&mut self, custom: Option<&CustomOpcodeConfig>) -> Token {
        self.skip_ws();
        let mut token = Token::new(self.line, TokenType::Eof);
        if self.eof() {
            return token;
        }
        let c = self.byte_at(0);
        if is_digit(c) || c == b'.' {
            self.scan_number(&mut token);
        } else if is_ident_begin(c) {
            self.scan_ident(&mut token);
            self.analyze_ident(&mut token, custom);
        } else if c == b'\'' {
            self.scan_binarr(&mut token);
        } else if c == b'"' {
            self.scan_string(&mut token);
        } else {
            self.scan_punct(&mut token, c);
        }
        token
    }

    // ------------------------------------------------------------ 数字

    fn scan_number(&mut self, token: &mut Token) {
        if self.starts_with("0b") || self.starts_with("0B") {
            token.type_ = TokenType::Integer;
            token.lexeme = self.match_radix_integer("01");
        } else if self.starts_with("0o") || self.starts_with("0O") {
            token.type_ = TokenType::Integer;
            token.lexeme = self.match_radix_integer("01234567");
        } else if self.starts_with("0x") || self.starts_with("0X") {
            token.type_ = TokenType::Integer;
            token.lexeme = self.match_radix_integer("0123456789abcdefABCDEF");
        } else if self.byte_at(0) == b'.' {
            // .[_0-9]*([eE][+-]?[0-9]+)?
            token.type_ = TokenType::Float;
            let mut lexeme = self.take_chars_while(|c| c == '.');
            lexeme.push_str(&self.take_chars_while(|c| c == '_' || c.is_ascii_digit()));
            let exp = self.scan_exponent();
            lexeme.push_str(&exp);
            token.lexeme = lexeme;
        } else {
            // [_0-9]+(.[_0-9]*)?([eE][+-]?[0-9]+)?
            token.type_ = TokenType::Integer;
            let mut lexeme = self.take_chars_while(|c| c == '_' || c.is_ascii_digit());
            if !self.eof() && self.byte_at(0) == b'.' {
                token.type_ = TokenType::Float;
                // \. ＋ [_0-9]*：只吃一个小数点（"1..2" 的第二个点是新 token）
                lexeme.push('.');
                self.pos += 1;
                let frac = self.take_chars_while(|c| c == '_' || c.is_ascii_digit());
                lexeme.push_str(&frac);
            }
            let exp = self.scan_exponent();
            if !exp.is_empty() {
                token.type_ = TokenType::Float;
            }
            lexeme.push_str(&exp);
            token.lexeme = lexeme;
        }
        // parse_number：数字字面量允许下划线分隔
        token.parsed = token.lexeme.replace('_', "");
        self.get_number_value(token);
    }

    /// 取走前缀能匹配的 `[_chars]+`；一个都没有时只取 "0?" 两字符（让后面报错）。
    fn match_radix_integer(&mut self, digits: &str) -> String {
        let rest = self.rest().to_string();
        let bytes = rest.as_bytes();
        let mut end = 2; // 跳过 "0b" / "0o" / "0x"
        while end < bytes.len() && (bytes[end] == b'_' || digits.as_bytes().contains(&bytes[end])) {
            end += 1;
        }
        // ^0[bB][_01]+：前缀后必须至少一位数字，否则只消费前缀
        let matched = end > 2;
        self.pos += end;
        if matched {
            rest[..end].to_string()
        } else {
            rest[..2].to_string()
        }
    }

    fn take_chars_while(&mut self, pred: impl Fn(char) -> bool) -> String {
        let rest = self.rest();
        let mut end = 0;
        for (i, c) in rest.char_indices() {
            if pred(c) {
                end = i + c.len_utf8();
            } else {
                break;
            }
        }
        let text = rest[..end].to_string();
        self.pos += end;
        text
    }

    /// `([eE][+-]?[0-9]*)?` —— 返回 "" 表示没有指数。
    /// 数字部分可以为空（"1e" 的 e 也算进 lexeme），交给 `get_number_value` 报错。
    fn scan_exponent(&mut self) -> String {
        if self.eof() {
            return String::new();
        }
        let c = self.byte_at(0);
        if c != b'e' && c != b'E' {
            return String::new();
        }
        let mut end = 1;
        let bytes = self.src.as_bytes();
        if self.pos + end < bytes.len() && (bytes[self.pos + end] == b'+' || bytes[self.pos + end] == b'-') {
            end += 1;
        }
        while self.pos + end < bytes.len() && is_digit(bytes[self.pos + end]) {
            end += 1;
        }
        let text = self.src[self.pos..self.pos + end].to_string();
        self.pos += end;
        text
    }

    /// 按 `parsed` 求数值；不合法（含超出 int64）则报错并把 token 置为 Invalid。
    fn get_number_value(&mut self, token: &mut Token) {
        if token.type_ == TokenType::Integer {
            let parsed = token.parsed.clone();
            let (base, prefix_len) = number_base(&parsed);
            let digits = &parsed[prefix_len..];
            let mut ok = !digits.is_empty()
                && digits.bytes().all(|c| match base {
                    2 => c == b'0' || c == b'1',
                    8 => (b'0'..=b'7').contains(&c),
                    10 => c.is_ascii_digit(),
                    _ => c.is_ascii_hexdigit(),
                });
            let mut value: i64 = 0;
            if ok {
                match i128::from_str_radix(digits, base) {
                    Ok(v) if v <= INT64_MAX as i128 => value = v as i64,
                    _ => ok = false, // 对齐 C++ stoll 的 out_of_range
                }
            }
            if !ok {
                self.error("invalid integer. ");
                token.type_ = TokenType::Invalid;
                return;
            }
            token.value = Some(Literal::Int(value));
        } else if token.type_ == TokenType::Float {
            let parsed = token.parsed.clone();
            // 校验 (digits(\.digits*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$：
            // 整数与小数部分不能同时为空（"."），指数若存在必须有数字（"1e"）
            let valid = {
                let (mant, exp) = split_float(&parsed);
                let mant_ok = match mant.split_once('.') {
                    // digits(.digits*)? | .digits+：整数与小数不能同时为空
                    Some((a, b)) => {
                        a.bytes().all(|c| c.is_ascii_digit())
                            && b.bytes().all(|c| c.is_ascii_digit())
                            && (!a.is_empty() || !b.is_empty())
                    }
                    None => !mant.is_empty() && mant.bytes().all(|c| c.is_ascii_digit()),
                };
                let exp_ok = match exp {
                    None => true,
                    Some(e) => {
                        let e = e.strip_prefix('+').or_else(|| e.strip_prefix('-')).unwrap_or(e);
                        !e.is_empty() && e.bytes().all(|c| c.is_ascii_digit())
                    }
                };
                mant_ok && exp_ok
            };
            if !valid {
                self.error("invalid float. ");
                token.type_ = TokenType::Invalid;
                return;
            }
            // Rust 的 f64 parse 不认 "5." / ".5" / "5.e3"，先规范化成等价形式
            let mut norm = parsed.clone();
            if norm.starts_with('.') {
                norm.insert(0, '0');
            }
            while norm.ends_with('.') {
                norm.pop();
            }
            if let Some(epos) = norm.find(['e', 'E']) {
                if norm[..epos].ends_with('.') {
                    norm.remove(epos - 1);
                }
            }
            let value: f64 = norm.parse().unwrap_or(f64::NAN);
            // C++ 用 stod，上溢与下溢都抛 out_of_range → Invalid：非有限值（1e999），
            // 或有非零数字却算出 0（1e-999 下溢）
            if !value.is_finite() || (value == 0.0 && parsed.bytes().any(|c| (b'1'..=b'9').contains(&c))) {
                self.error("invalid float. ");
                token.type_ = TokenType::Invalid;
                return;
            }
            token.value = Some(Literal::Float(value));
        }
    }

    // ------------------------------------------------------------ 序列 / 字符串

    /// `'...'` 到下一个 `'` 为止，中间可以换行（换行计入 line）。
    fn scan_binarr(&mut self, token: &mut Token) {
        token.type_ = TokenType::BinArr;
        self.pos += 1; // 跳过开头的 '
        let rest = self.rest();
        let end = rest.find('\'').unwrap_or(rest.len());
        let body = rest[..end].to_string();
        self.line += body.bytes().filter(|&c| c == b'\n').count() as i32;
        self.pos += end;
        if self.eof() {
            // 没扫到闭合的 '
            self.error("unclosed binary array. ");
            token.type_ = TokenType::Invalid;
            token.lexeme = body;
            return;
        }
        token.lexeme = body;
        self.pos += 1; // 跳过结尾的 '
    }

    /// `"..."` 里的 `\` 会转义后一个字符（含 `\"`），未闭合则报错。
    fn scan_string(&mut self, token: &mut Token) {
        token.type_ = TokenType::String;
        self.pos += 1; // 跳过开头的 "
        let rest = self.rest();
        let bytes = rest.as_bytes();
        let mut i = 0usize;
        let mut end = rest.len();
        while i < bytes.len() {
            match bytes[i] {
                b'\\' => {
                    if i + 1 >= bytes.len() {
                        end = i; // 末尾孤立的 \：body 停在它前面
                        break;
                    }
                    i += 2; // 转义对整体跳过（含多字节字符也没问题：边界只由 " \ 决定）
                }
                b'"' => {
                    end = i;
                    break;
                }
                _ => i += 1,
            }
        }
        let body = rest[..end].to_string();
        self.pos += end;
        if self.eof() || self.byte_at(0) != b'"' {
            // 没扫到闭合的 "（吃掉剩余全部输入，与 C++ / Python 一致）
            self.error("unclosed string literal. ");
            token.type_ = TokenType::Invalid;
            token.lexeme = body;
            self.pos = self.src.len();
            return;
        }
        token.lexeme = body;
        self.pos += 1; // 跳过结尾的 "
        self.escape_string(token);
    }

    /// 处理转义序列；遇到非法转义就报错并停下（已解析的部分保留）。
    fn escape_string(&mut self, token: &mut Token) {
        let lexeme = token.lexeme.clone();
        let bytes = lexeme.as_bytes();
        let mut parsed = String::with_capacity(lexeme.len());
        let mut i = 0usize;
        while i < bytes.len() {
            if bytes[i] == b'\\' {
                i += 1;
                if i >= bytes.len() {
                    self.error("invalid escape character. ");
                    break;
                }
                match escape_char(bytes[i]) {
                    Some(c) => parsed.push(c),
                    None => {
                        self.error("invalid escape character. ");
                        break;
                    }
                }
                i += 1;
            } else {
                // 非转义位置按 char 拷贝（多字节字符安全：内部不会是 \ 或截断点）
                let ch_len = utf8_len(bytes[i]);
                parsed.push_str(&lexeme[i..i + ch_len]);
                i += ch_len;
            }
        }
        token.parsed = parsed;
    }

    // ------------------------------------------------------------ 标识符

    /// `^[a-zA-Z_][a-zA-Z0-9_]*(:[a-zA-Z_][a-zA-Z0-9_]*)*`，冒号两侧允许空白与注释。
    fn scan_ident(&mut self, token: &mut Token) {
        token.type_ = TokenType::Ident;
        let mut src_parts: Vec<String> = Vec::new();
        let mut parsed = self.take_chars_while(is_ident_char_c);
        src_parts.push(parsed.clone());
        loop {
            let skipped = self.skip_ws_returning_skipped();
            src_parts.push(skipped);
            if self.eof() || self.byte_at(0) != b':' {
                break;
            }
            src_parts.push(":".to_string());
            parsed.push(':');
            self.pos += 1;
            let skipped = self.skip_ws_returning_skipped();
            src_parts.push(skipped);
            if self.eof() || !is_ident_begin(self.byte_at(0)) {
                // 冒号后面不是标识符
                self.error("unclosed identifier. ");
                token.type_ = TokenType::Invalid;
                break;
            }
            let text = self.take_chars_while(is_ident_char_c);
            src_parts.push(text.clone());
            parsed.push_str(&text);
        }
        token.lexeme = src_parts.concat();
        token.parsed = parsed;
    }

    fn analyze_ident(&mut self, token: &mut Token, custom: Option<&CustomOpcodeConfig>) {
        if token.type_ == TokenType::Invalid {
            return;
        }
        token.type_ = match token.parsed.as_str() {
            "idiv" => TokenType::IDiv,
            "not" => TokenType::Not,
            "and" => TokenType::And,
            "or" => TokenType::Or,
            "if" => TokenType::If,
            "elif" => TokenType::Elif,
            "else" => TokenType::Else,
            "let" => TokenType::Let,
            "return" => TokenType::Return,
            "while" => TokenType::While,
            "break" => TokenType::Break,
            "continue" => TokenType::Continue,
            "null" => TokenType::Null,
            "false" => TokenType::False,
            "true" => TokenType::True,
            "args" => TokenType::Args,
            "argc" => TokenType::Argc,
            "export" => TokenType::Export,
            // 关键字 > 自定义指令 > 标识符
            s if custom.map(|c| c.find(s).is_some()).unwrap_or(false) => TokenType::Custom,
            _ => TokenType::Ident,
        };
    }

    // ------------------------------------------------------------ 标点 / 空白

    fn scan_punct(&mut self, token: &mut Token, c: u8) {
        let two = match self.rest().get(..2) {
            Some("==") => Some(TokenType::EQ),
            Some("!=") => Some(TokenType::NE),
            Some("<=") => Some(TokenType::LE),
            Some(">=") => Some(TokenType::GE),
            Some("&&") => Some(TokenType::And),
            Some("||") => Some(TokenType::Or),
            _ => None,
        };
        if let Some(t) = two {
            token.type_ = t;
            token.lexeme = self.src[self.pos..self.pos + 2].to_string();
            self.pos += 2;
            return;
        }
        let one = match c {
            b',' => Some(TokenType::Comma),
            b';' => Some(TokenType::Semi),
            b'(' => Some(TokenType::LParen),
            b')' => Some(TokenType::RParen),
            b'[' => Some(TokenType::LBrack),
            b']' => Some(TokenType::RBrack),
            b'{' => Some(TokenType::LBrace),
            b'}' => Some(TokenType::RBrace),
            b'+' => Some(TokenType::Add),
            b'-' => Some(TokenType::Sub),
            b'*' => Some(TokenType::Mul),
            b'/' => Some(TokenType::Div),
            b'%' => Some(TokenType::Mod),
            b'^' => Some(TokenType::Pow),
            b'=' => Some(TokenType::Assign),
            b'!' => Some(TokenType::Not),
            b'<' => Some(TokenType::LT),
            b'>' => Some(TokenType::GT),
            _ => None,
        };
        token.type_ = one.unwrap_or(TokenType::Invalid);
        token.lexeme = (c as char).to_string();
        self.pos += 1;
        if one.is_none() {
            self.error("unknown token. ");
        }
    }

    fn skip_ws(&mut self) {
        loop {
            if self.eof() {
                break;
            }
            let c = self.byte_at(0);
            if is_white(c) {
                if c == b'\n' {
                    self.line += 1;
                }
                self.pos += 1;
            } else if self.starts_with("//") {
                // 单行注释
                match self.rest().find('\n') {
                    None => self.pos = self.src.len(),
                    Some(p) => {
                        self.pos += p + 1;
                        self.line += 1;
                    }
                }
            } else if self.starts_with("/*") {
                self.skip_multiline_comment();
            } else {
                break;
            }
        }
    }

    /// 与 [`Lexer::skip_ws`] 相同，但返回被跳过的原文（标识符的 `:` 两侧要记进 lexeme）。
    fn skip_ws_returning_skipped(&mut self) -> String {
        let before = self.pos;
        self.skip_ws();
        self.src[before..self.pos].to_string()
    }

    fn skip_multiline_comment(&mut self) {
        self.pos += 2; // 跳过 /*
        while !self.eof() {
            if self.starts_with("*/") {
                self.pos += 2;
                break;
            }
            if self.byte_at(0) == b'\n' {
                self.line += 1;
            }
            self.pos += 1;
        }
    }
}

fn is_ident_char_c(c: char) -> bool {
    c == '_' || c.is_ascii_alphanumeric()
}

fn utf8_len(b: u8) -> usize {
    if b < 0x80 {
        1
    } else if b >> 5 == 0b110 {
        2
    } else if b >> 4 == 0b1110 {
        3
    } else {
        4
    }
}

/// 按字面量前缀决定基数，并给出前缀长度。
fn number_base(s: &str) -> (u32, usize) {
    let b = s.as_bytes();
    if b.len() >= 2 && b[0] == b'0' {
        match b[1] {
            b'b' | b'B' => return (2, 2),
            b'o' | b'O' => return (8, 2),
            b'x' | b'X' => return (16, 2),
            _ => {}
        }
    }
    (10, 0)
}

/// 把 "123.45e+6" 拆成 ("123.45", Some("+6"))（指数不含 e/E 前缀）。
fn split_float(s: &str) -> (&str, Option<&str>) {
    match s.find(['e', 'E']) {
        Some(p) => (&s[..p], Some(&s[p + 1..])),
        None => (s, None),
    }
}
