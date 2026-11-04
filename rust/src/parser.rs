//! 语法分析器（Pratt）—— 对齐 `python/stope/parser.py` / `cpp/src/parser.cpp`。
//!
//! 行为契约：
//!
//! 1. **错误恢复：分隔符缺失时只报错、不推进**，把后续 token 留给下一条语句重新
//!    解析。例外：`parse_let_stmt` / `parse_return_stmt` 的兜底分支仍会推进；
//! 2. 不变量：`parse_expr()` 之后必有一次 `next_token()`；
//! 3. 顶层孤立 `}` 要报错**并跳过**继续解析；块内的 `}` 由外层消费，不报错；
//! 4. 常量折叠挂在 `parse_unary_op_expr` / `parse_binary_op_expr` 的构造末尾；
//! 5. 节点取 token 的 `parsed` 而非 `lexeme`；只有 BinArr 取 `lexeme`。
//!
//! 嵌套深度上限 256（`max_depth`，0 = 不限）：`depth` 走函数参数。超限时报一条
//! `line N: nesting too deep (max 256). ` 并置 `aborted`（此后所有 `error()` 都不再
//! 记账），子函数返回 `None` 但**不逐层传染**。
//!
//! 注：abort 传播路径上，Python 会把「带 None 子节点的」节点继续返回（除括号透传
//! None）。本实现用 `Expr::Err(-1)` 占位那些 None 子节点 —— abort 之后不再有形状
//! 断言，两条路径的语义（不折叠、不产出可观测错误）保持一致。

use crate::ast::{self, Expr, Prog, Stmt, IfStmtElif};
use crate::binarr::parse_binary_array;
use crate::common::Result as StopeResult;
use crate::lexer::Lexer;
use crate::opcode::CustomOpcodeConfig;
use crate::token::TokenType;
use std::rc::Rc;

/// 默认嵌套深度上限（与 C++ `Parser::maxDepth` 相同，文案也逐字相同）。
pub const K_DEFAULT_MAX_DEPTH: i32 = ast::K_DEFAULT_MAX_DEPTH;

pub struct Parser {
    lexer: Lexer,
    custom: Option<Rc<CustomOpcodeConfig>>,
    pub errors: Vec<String>,
    pub aborted: bool,
    pub const_folding: bool,
    pub max_depth: i32,
    cur_token: crate::token::Token,
    peek_token: crate::token::Token,
}

impl Parser {
    /// `Parser(lexer, custom)`。先读两个 token，cur / peek 才都有值。
    pub fn new(src: &str, custom: Option<Rc<CustomOpcodeConfig>>) -> Self {
        Parser::with_lexer(Lexer::new(src), custom)
    }

    /// 从既有词法器构造（demo04 用：先把起始行号设成 STML 里的物理行号）。
    pub fn with_lexer(lexer: Lexer, custom: Option<Rc<CustomOpcodeConfig>>) -> Self {
        let mut p = Parser {
            lexer,
            custom,
            errors: Vec::new(),
            aborted: false,
            const_folding: true,
            max_depth: K_DEFAULT_MAX_DEPTH,
            cur_token: Default::default(),
            peek_token: Default::default(),
        };
        p.next_token();
        p.next_token();
        p
    }

    /// 词法器只读访问（errors / line 等）。
    pub fn lexer(&self) -> &Lexer {
        &self.lexer
    }

    /// 与 C++ 的 `Parser::Reset` 一致：清错误、重挂词法器、重读两个 token。
    pub fn reset(&mut self, src: &str, custom: Option<Rc<CustomOpcodeConfig>>) {
        self.errors.clear();
        self.aborted = false;
        self.const_folding = true;
        self.max_depth = K_DEFAULT_MAX_DEPTH;
        self.lexer.reset(src);
        self.custom = custom;
        self.next_token();
        self.next_token();
    }

    pub fn parse_program(&mut self, prog: &mut Prog) {
        self.parse_prog(prog, true, 1);
    }

    // ================================ 语句 ================================

    /// `is_top_level=true` 只有 `parse_program` 用：块内的 `}` 属于外层语句。
    fn parse_prog(&mut self, prog: &mut Prog, is_top_level: bool, depth: i32) {
        if self.aborted {
            return;
        }
        while !self.aborted && self.cur_token.type_ != TokenType::Eof {
            let t = self.cur_token.type_;
            if t == TokenType::RBrace {
                if !is_top_level {
                    break; // 块内：正常结束，不跳过，交给外层处理
                }
                let line = self.cur_token.line;
                self.error(line, "unexpected \"}\" at top level. ");
                self.next_token();
                continue;
            }
            if t == TokenType::Semi {
                // 空语句
                self.next_token();
                continue;
            }
            let stmt = match t {
                TokenType::Let => self.parse_let_stmt(depth),
                TokenType::Export => self.parse_export_stmt(),
                TokenType::Return => self.parse_return_stmt(depth),
                TokenType::LBrace => self.parse_block_stmt(depth),
                TokenType::If => self.parse_if_stmt(depth),
                TokenType::While => self.parse_while_stmt(depth),
                TokenType::Break => self.parse_break_stmt(),
                TokenType::Continue => self.parse_continue_stmt(),
                _ => self.parse_expr_or_assign_stmt(depth), // 表达式语句或赋值语句
            };
            // 超限中止时子函数返回 None：不追加、不再往下解析
            let Some(stmt) = stmt else { break };
            prog.stmts.push(stmt);
        }
    }

    fn parse_let_stmt(&mut self, depth: i32) -> Option<Stmt> {
        let line = self.cur_token.line;
        let mut idents: Vec<String> = Vec::new();
        let mut has_assign = false;
        let mut expr: Option<Box<Expr>> = None;
        self.next_token(); // 跳过 let
        if self.cur_token.type_ != TokenType::Ident {
            let l = self.cur_token.line;
            self.error(l, "expected identifier after \"let\". ");
            self.next_token();
            return Some(Stmt::Let { line, has_assign, idents, expr });
        }
        idents.push(self.cur_token.parsed.clone());
        self.next_token();
        if self.cur_token.type_ == TokenType::Semi {
            // 单个标识符且不赋值
            self.next_token();
        } else if self.cur_token.type_ == TokenType::Comma {
            // 多个标识符，禁止赋值
            loop {
                if self.cur_token.type_ == TokenType::Comma
                    && self.peek_token.type_ == TokenType::Ident
                {
                    idents.push(self.peek_token.parsed.clone());
                    self.next_token();
                    self.next_token();
                } else if self.cur_token.type_ == TokenType::Semi {
                    self.next_token();
                    break;
                } else if self.cur_token.type_ == TokenType::Eof
                    || self.cur_token.type_ == TokenType::RBrace
                {
                    // 缺 ";": 此处不能再推进（Eof 上推进会死循环，推进又会吞掉 "}"）
                    let l = self.cur_token.line;
                    self.error(l, "expected \";\" in let statement. ");
                    break;
                } else {
                    let l = self.cur_token.line;
                    self.error(l, "failed to parse let statement with multiple identifiers. ");
                    self.next_token();
                }
            }
        } else if self.cur_token.type_ == TokenType::Assign {
            has_assign = true;
            self.next_token();
            expr = self.parse_expr(ast::precedence::LOWEST, depth).map(Box::new);
            self.next_token();
        } else {
            let l = self.cur_token.line;
            self.error(l, "unexpected token in let statement. ");
            self.next_token();
        }
        Some(Stmt::Let { line, has_assign, idents, expr })
    }

    fn parse_export_stmt(&mut self) -> Option<Stmt> {
        let line = self.cur_token.line;
        let mut idents: Vec<String> = Vec::new();
        self.next_token(); // 跳过 export
        if self.cur_token.type_ != TokenType::Ident {
            let l = self.cur_token.line;
            self.error(l, "expected identifier after \"export\". ");
            self.next_token();
            return Some(Stmt::Export { line, idents });
        }
        idents.push(self.cur_token.parsed.clone());
        self.next_token();
        if self.cur_token.type_ == TokenType::Semi {
            self.next_token();
        } else if self.cur_token.type_ == TokenType::Comma {
            loop {
                if self.cur_token.type_ == TokenType::Comma
                    && self.peek_token.type_ == TokenType::Ident
                {
                    idents.push(self.peek_token.parsed.clone());
                    self.next_token();
                    self.next_token();
                } else if self.cur_token.type_ == TokenType::Semi {
                    self.next_token();
                    break;
                } else if self.cur_token.type_ == TokenType::Eof
                    || self.cur_token.type_ == TokenType::RBrace
                {
                    let l = self.cur_token.line;
                    self.error(l, "expected \";\" in export statement. ");
                    break;
                } else {
                    let l = self.cur_token.line;
                    self.error(l, "failed to parse export statement with multiple identifiers. ");
                    self.next_token();
                }
            }
        } else {
            let l = self.cur_token.line;
            self.error(l, "unexpected token in export statement. ");
            self.next_token();
        }
        Some(Stmt::Export { line, idents })
    }

    fn parse_return_stmt(&mut self, depth: i32) -> Option<Stmt> {
        // return_stmt : "return" ( expr ( "," expr )* )? ";"
        let line = self.cur_token.line;
        let mut exprs: Vec<Expr> = Vec::new();
        self.next_token(); // 跳过 return
        if self.cur_token.type_ == TokenType::Semi {
            // 无返回值，exprs 为空
            self.next_token();
            return Some(Stmt::Return { line, exprs });
        }
        if self.cur_token.type_ == TokenType::Eof || self.cur_token.type_ == TokenType::RBrace {
            // 缺 ";": 此时不能吞掉 } 或 Eof，否则外层块会解析错位
            let l = self.cur_token.line;
            self.error(l, "expected \";\" in return statement. ");
            return Some(Stmt::Return { line, exprs });
        }
        exprs.push(self.parse_expr(ast::precedence::LOWEST, depth).unwrap_or(Expr::Err(-1))); // 第一个表达式
        self.next_token(); // 到达 , 或 ;
        loop {
            if self.cur_token.type_ == TokenType::Semi {
                self.next_token();
                break;
            } else if self.cur_token.type_ == TokenType::Comma {
                self.next_token();
                exprs.push(self.parse_expr(ast::precedence::LOWEST, depth).unwrap_or(Expr::Err(-1)));
                self.next_token();
            } else {
                let l = self.cur_token.line;
                self.error(l, "expected \";\" or \",\" in return statement. ");
                self.next_token();
                break;
            }
        }
        Some(Stmt::Return { line, exprs })
    }

    fn parse_block_stmt(&mut self, depth: i32) -> Option<Stmt> {
        if self.aborted {
            return None; // 已超限：不再解析
        }
        let line = self.cur_token.line;
        self.next_token(); // 跳过 {
        let mut prog = Prog::new(-1);
        self.parse_prog(&mut prog, false, depth + 1);
        if self.cur_token.type_ != TokenType::RBrace {
            let l = self.cur_token.line;
            self.error(l, "expected \"}\" at end of block statement. ");
        }
        self.next_token(); // 跳过 }
        Some(Stmt::Block { line, prog })
    }

    fn parse_if_stmt(&mut self, depth: i32) -> Option<Stmt> {
        // if_stmt : "if" expr "{" prog "}" ("elif" expr "{" prog "}")* ("else" "{" prog "}")?
        if self.aborted {
            return None;
        }
        let line = self.cur_token.line;
        self.next_token(); // 跳过 if
        let cond = self.parse_expr(ast::precedence::LOWEST, depth).unwrap_or(Expr::Err(-1));
        self.next_token(); // 到达 {
        if self.cur_token.type_ != TokenType::LBrace {
            let l = self.cur_token.line;
            self.error(l, "expected \"{\" in if statement. ");
            return Some(Stmt::If {
                line,
                cond: Box::new(cond),
                first_prog: Prog::new(-1),
                elifs: Vec::new(),
                else_prog: None,
            });
        }
        self.next_token(); // 跳过 {
        let mut first_prog = Prog::new(-1);
        self.parse_prog(&mut first_prog, false, depth + 1);
        if self.cur_token.type_ != TokenType::RBrace {
            let l = self.cur_token.line;
            self.error(l, "expected \"}\" in if statement. ");
            return Some(Stmt::If {
                line,
                cond: Box::new(cond),
                first_prog,
                elifs: Vec::new(),
                else_prog: None,
            });
        }
        self.next_token(); // 跳过 }
        let mut elifs: Vec<IfStmtElif> = Vec::new();
        while self.cur_token.type_ == TokenType::Elif {
            // ("elif" expr "{" prog "}")*
            let ei_line = self.cur_token.line;
            self.next_token(); // 跳过 elif
            let ei_cond =
                self.parse_expr(ast::precedence::LOWEST, depth).unwrap_or(Expr::Err(-1));
            self.next_token();
            if self.cur_token.type_ != TokenType::LBrace {
                let l = self.cur_token.line;
                self.error(l, "expected \"{\" of elif. ");
                return Some(Stmt::If {
                    line,
                    cond: Box::new(cond),
                    first_prog,
                    elifs,
                    else_prog: None,
                });
            }
            self.next_token(); // 跳过 {
            let mut ei_prog = Prog::new(-1);
            self.parse_prog(&mut ei_prog, false, depth + 1);
            if self.cur_token.type_ != TokenType::RBrace {
                let l = self.cur_token.line;
                self.error(l, "expected \"}\" of elif. ");
                return Some(Stmt::If {
                    line,
                    cond: Box::new(cond),
                    first_prog,
                    elifs,
                    else_prog: None,
                });
            }
            self.next_token(); // 跳过 }
            elifs.push(IfStmtElif { line: ei_line, cond: Box::new(ei_cond), prog: ei_prog });
        }
        let mut else_prog = None;
        if self.cur_token.type_ == TokenType::Else {
            self.next_token();
            if self.cur_token.type_ != TokenType::LBrace {
                let l = self.cur_token.line;
                self.error(l, "expected \"{\" after else. ");
                return Some(Stmt::If {
                    line,
                    cond: Box::new(cond),
                    first_prog,
                    elifs,
                    else_prog: None,
                });
            }
            self.next_token(); // 跳过 {
            let mut ep = Prog::new(-1);
            self.parse_prog(&mut ep, false, depth + 1);
            if self.cur_token.type_ != TokenType::RBrace {
                let l = self.cur_token.line;
                self.error(l, "expected \"}\" in if statement. ");
                return Some(Stmt::If {
                    line,
                    cond: Box::new(cond),
                    first_prog,
                    elifs,
                    else_prog: None,
                });
            }
            self.next_token(); // 跳过 }
            else_prog = Some(ep);
        }
        Some(Stmt::If { line, cond: Box::new(cond), first_prog, elifs, else_prog })
    }

    fn parse_while_stmt(&mut self, depth: i32) -> Option<Stmt> {
        // while_stmt : "while" expr? "{" prog "}"
        if self.aborted {
            return None;
        }
        let line = self.cur_token.line;
        self.next_token(); // 跳过 while
        let mut cond: Option<Box<Expr>> = None;
        if self.cur_token.type_ != TokenType::LBrace {
            cond = self.parse_expr(ast::precedence::LOWEST, depth).map(Box::new);
            self.next_token(); // 到达 {
        }
        if self.cur_token.type_ != TokenType::LBrace {
            let l = self.cur_token.line;
            self.error(l, "expected \"{\" in while statement. ");
            return Some(Stmt::While { line, cond, prog: Prog::new(-1) });
        }
        self.next_token(); // 跳过 {
        let mut prog = Prog::new(-1);
        self.parse_prog(&mut prog, false, depth + 1);
        if self.cur_token.type_ != TokenType::RBrace {
            let l = self.cur_token.line;
            self.error(l, "expected \"}\" at end of while statement. ");
            return Some(Stmt::While { line, cond, prog });
        }
        self.next_token();
        Some(Stmt::While { line, cond, prog })
    }

    fn parse_break_stmt(&mut self) -> Option<Stmt> {
        let line = self.cur_token.line;
        self.next_token(); // 跳过 break
        if self.cur_token.type_ != TokenType::Semi {
            let l = self.cur_token.line;
            self.error(l, "expected \";\" in break statement. ");
        } else {
            self.next_token();
        }
        Some(Stmt::Break(line))
    }

    fn parse_continue_stmt(&mut self) -> Option<Stmt> {
        let line = self.cur_token.line;
        self.next_token(); // 跳过 continue
        if self.cur_token.type_ != TokenType::Semi {
            let l = self.cur_token.line;
            self.error(l, "expected \";\" in continue statement. ");
        } else {
            self.next_token();
        }
        Some(Stmt::Continue(line))
    }

    fn parse_expr_or_assign_stmt(&mut self, depth: i32) -> Option<Stmt> {
        let left_expr = self.parse_expr(ast::precedence::LOWEST, depth)?;
        self.next_token(); // 到达 = 或 ;
        if self.cur_token.type_ == TokenType::Semi {
            self.next_token(); // 跳过 ;
            let line = left_expr.line();
            return Some(Stmt::ExprStmt { line, expr: Box::new(left_expr) });
        } else if self.cur_token.type_ == TokenType::Assign {
            self.next_token(); // 跳过 =
            let line = left_expr.line();
            let right = self
                .parse_expr(ast::precedence::LOWEST, depth)
                .unwrap_or(Expr::Err(-1));
            self.next_token(); // 到达 ;
            if self.cur_token.type_ != TokenType::Semi {
                let l = self.cur_token.line;
                self.error(l, "expected \";\" at end of assign statement. ");
            }
            self.next_token();
            return Some(Stmt::Assign { line, left: Box::new(left_expr), right: Box::new(right) });
        }
        let l = self.cur_token.line;
        self.error(l, "expected \";\" or \"=\". ");
        // 不推进：当前 token 不是合法的语句边界，留给下一轮语句解析。
        let line = left_expr.line();
        Some(Stmt::ExprStmt { line, expr: Box::new(left_expr) })
    }

    // ================================ 表达式主循环 ================================

    /// 返回 None 仅当中止传播（括号会原样透出）。
    fn parse_expr(&mut self, precedence: i32, depth: i32) -> Option<Expr> {
        // 深度检查只在这里和 parse_prog 做 —— 只有这两处会递归。
        if self.aborted {
            return None;
        }
        if self.max_depth > 0 && depth > self.max_depth {
            let line = self.cur_token.line;
            self.abort_too_deep(line);
            return None;
        }
        let tt = self.cur_token.type_;
        let mut left_expr = match tt {
            TokenType::Ident => Some(self.parse_ident_expr()),
            TokenType::Null => Some(Expr::Null(self.cur_token.line)),
            TokenType::False => Some(Expr::Bool(self.cur_token.line, false)),
            TokenType::True => Some(Expr::Bool(self.cur_token.line, true)),
            TokenType::Integer => Some(Expr::Int(self.cur_token.line, self.cur_token.int_value())),
            TokenType::Float => {
                Some(Expr::Float(self.cur_token.line, self.cur_token.float_value()))
            }
            TokenType::String => {
                Some(Expr::Str(self.cur_token.line, self.cur_token.parsed.clone()))
            }
            TokenType::BinArr => Some(self.parse_binarr_expr()),
            TokenType::Argc => Some(Expr::Argc(self.cur_token.line)),
            TokenType::Sub | TokenType::Not => self.parse_unary_op_expr(depth),
            TokenType::LParen => self.parse_paren_expr(depth),
            TokenType::Custom => self.parse_custom_opcode_expr(depth),
            TokenType::Args => self.parse_args_expr(depth),
            _ => {
                let line = self.cur_token.line;
                self.error(line, "no prefix parse function for token type. ");
                Some(Expr::Err(line)) // 失败路径返回裸节点，形状为 Err(L行号)
            }
        }?;
        while !self.aborted
            && self.peek_token.type_ != TokenType::Semi
            && precedence < ast::binop_prec(self.peek_token.type_)
        {
            let pt = self.peek_token.type_;
            match pt {
                TokenType::Or
                | TokenType::And
                | TokenType::EQ
                | TokenType::NE
                | TokenType::LT
                | TokenType::LE
                | TokenType::GT
                | TokenType::GE
                | TokenType::Add
                | TokenType::Sub
                | TokenType::Mul
                | TokenType::Div
                | TokenType::IDiv
                | TokenType::Mod
                | TokenType::Pow => {
                    self.next_token();
                    left_expr = self.parse_binary_op_expr(left_expr, depth);
                }
                TokenType::LParen => {
                    self.next_token();
                    left_expr = self.parse_call_expr(left_expr, depth);
                }
                TokenType::LBrack => {
                    self.next_token();
                    left_expr = self.parse_at_expr(left_expr, depth);
                }
                _ => {
                    let line = self.peek_token.line;
                    self.error(line, "no infix parse function for token type. ");
                    return Some(left_expr);
                }
            }
        }
        Some(left_expr)
    }

    fn optimize_in_place(&self, e: Expr) -> Expr {
        if !self.const_folding {
            return e;
        }
        crate::expr_optim::optimize(e)
    }

    // ================================ 基础设施 ================================

    fn next_token(&mut self) {
        self.cur_token = std::mem::take(&mut self.peek_token);
        self.peek_token = self.lexer.next_token(self.custom.as_deref());
    }

    fn error(&mut self, line: i32, msg: &str) {
        // 嵌套超限中止之后的一切错误都是连锁反应，不再记账
        if self.aborted {
            return;
        }
        self.errors.push(format!("line {}: {}", line, msg));
    }

    fn abort_too_deep(&mut self, line: i32) {
        // 必须在置位之前记账
        let msg = format!("nesting too deep (max {}). ", self.max_depth);
        self.error(line, &msg);
        self.aborted = true;
    }

    pub fn has_err(&self) -> bool {
        !self.errors.is_empty()
    }

    // ================================ 前缀 ================================

    fn parse_ident_expr(&self) -> Expr {
        Expr::Ident(self.cur_token.line, self.cur_token.parsed.clone())
    }

    fn parse_binarr_expr(&mut self) -> Expr {
        let line = self.cur_token.line;
        // 取 lexeme：二进制数组不做转义，解析到一半失败也要保留前半段
        let mut buf: Vec<u8> = Vec::new();
        let rc = parse_binary_array(&self.cur_token.lexeme, &mut buf);
        if rc != StopeResult::Success {
            self.error(line, "invalid binary array. ");
        }
        Expr::BinArr(line, Rc::new(buf))
    }

    fn parse_unary_op_expr(&mut self, depth: i32) -> Option<Expr> {
        let line = self.cur_token.line;
        let op = self.cur_token.type_;
        self.next_token();
        // 子表达式已折好，这里折自己（自底向上）；abort 时用 Err 占位
        let sub = self
            .parse_expr(ast::precedence::PREFIX, depth + 1)
            .unwrap_or(Expr::Err(-1));
        Some(self.optimize_in_place(Expr::UnaryOp { line, op, expr: Box::new(sub) }))
    }

    fn parse_paren_expr(&mut self, depth: i32) -> Option<Expr> {
        self.next_token();
        let e = self.parse_expr(ast::precedence::LOWEST, depth + 1)?; // abort 透传
        self.next_token();
        if self.cur_token.type_ != TokenType::RParen {
            let l = self.cur_token.line;
            self.error(l, "expected \")\". ");
        }
        Some(e) // 停在 )
    }

    fn parse_custom_opcode_expr(&mut self, depth: i32) -> Option<Expr> {
        let line = self.cur_token.line;
        let opcode_name = self.cur_token.parsed.clone();
        self.next_token(); // 到达 (
        let mut args: Vec<Expr> = Vec::new();
        if self.cur_token.type_ != TokenType::LParen {
            let l = self.cur_token.line;
            self.error(l, "expected \"(\" after custom opcode. ");
            self.next_token();
            return Some(Expr::CustomOpcode { line, opcode_name, args });
        }
        self.next_token();
        if self.cur_token.type_ == TokenType::RParen {
            // 空参数表，cur 停在 )
        } else {
            // expr ("," expr)*
            args.push(self.parse_expr(ast::precedence::LOWEST, depth + 1).unwrap_or(Expr::Err(-1)));
            while self.peek_token.type_ == TokenType::Comma {
                self.next_token();
                self.next_token();
                args.push(
                    self.parse_expr(ast::precedence::LOWEST, depth + 1).unwrap_or(Expr::Err(-1)),
                );
            }
            if self.peek_token.type_ != TokenType::RParen {
                let l = self.cur_token.line;
                self.error(l, "expected \")\". ");
            }
            self.next_token(); // 到达 )
        }
        Some(Expr::CustomOpcode { line, opcode_name, args })
    }

    fn parse_args_expr(&mut self, depth: i32) -> Option<Expr> {
        let line = self.cur_token.line;
        if self.peek_token.type_ != TokenType::LBrack {
            // 不推进（cur 停在 "args"）：把后续 token 留给下一条语句，避免吞掉
            let l = self.peek_token.line;
            self.error(l, "expected \"[\" after \"args\". ");
            return Some(Expr::Args { line, key_expr: None });
        }
        self.next_token(); // 到达 [
        self.next_token();
        let key_expr = self.parse_expr(ast::precedence::LOWEST, depth + 1);
        self.next_token();
        if self.cur_token.type_ != TokenType::RBrack {
            let l = self.cur_token.line;
            self.error(l, "expected \"]\". ");
        }
        Some(Expr::Args { line, key_expr: key_expr.map(Box::new) })
    }

    // ================================ 中缀 ================================

    fn parse_binary_op_expr(&mut self, left_expr: Expr, depth: i32) -> Expr {
        let line = left_expr.line();
        let op = self.cur_token.type_;
        let mut prec = ast::binop_prec(op);
        // ^ 右结合：优先级 -1 让右侧继续吃同级的 ^（2^3^2 = 2^(3^2)）
        if op == TokenType::Pow {
            prec -= 1;
        }
        self.next_token();
        let right = self
            .parse_expr(prec, depth + 1)
            .unwrap_or(Expr::Err(-1)); // abort 占位
        // 两侧都已折好，折叠只在最深的节点先发生
        self.optimize_in_place(Expr::BinaryOp {
            line,
            op,
            left: Box::new(left_expr),
            right: Box::new(right),
        })
    }

    fn parse_call_expr(&mut self, callee: Expr, depth: i32) -> Expr {
        let line = callee.line();
        let mut args: Vec<Expr> = Vec::new();
        // 外层已保证此处是 (
        if self.peek_token.type_ != TokenType::RParen {
            // expr ("," expr)*
            self.next_token(); // 到达第一个表达式
            args.push(self.parse_expr(ast::precedence::LOWEST, depth + 1).unwrap_or(Expr::Err(-1)));
            while self.peek_token.type_ == TokenType::Comma {
                self.next_token(); // 到达 ","
                self.next_token(); // 到达下一个表达式
                args.push(
                    self.parse_expr(ast::precedence::LOWEST, depth + 1).unwrap_or(Expr::Err(-1)),
                );
            }
        }
        if self.peek_token.type_ == TokenType::RParen {
            self.next_token(); // 跳过 )
        } else {
            // 缺 ")" 时不推进，避免吞掉后面的 token
            let l = self.peek_token.line;
            self.error(l, "expected \")\". ");
        }
        Expr::Call { line, callee: Box::new(callee), args }
    }

    fn parse_at_expr(&mut self, container: Expr, depth: i32) -> Expr {
        let line = container.line();
        let mut key_exprs: Vec<Expr> = Vec::new();
        if self.peek_token.type_ != TokenType::RBrack {
            // expr ("," expr)*
            self.next_token(); // 到达第一个表达式
            key_exprs
                .push(self.parse_expr(ast::precedence::LOWEST, depth + 1).unwrap_or(Expr::Err(-1)));
            while self.peek_token.type_ == TokenType::Comma {
                self.next_token(); // 到达 ","
                self.next_token(); // 到达下一个表达式
                key_exprs
                    .push(self.parse_expr(ast::precedence::LOWEST, depth + 1).unwrap_or(Expr::Err(-1)));
            }
        }
        if self.peek_token.type_ == TokenType::RBrack {
            self.next_token(); // 跳过 ]
        } else {
            // 缺 "]" 时不推进，避免吞掉后面的 token
            let l = self.peek_token.line;
            self.error(l, "expected \"]\". ");
        }
        Expr::At { line, container: Box::new(container), key_exprs }
    }
}
