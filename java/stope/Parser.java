package stope;

import java.util.ArrayList;
import java.util.List;
import stope.Ast.*;

/** 语法分析器（Pratt）—— 照搬 python/stope/parser.py，对齐 cpp/src/parser.cpp。
 *  深度走函数参数；超限报一条并置 aborted；分隔符缺失只报错不推进（let/return 例外）。 */
public final class Parser {
    public static final int kDefaultMaxDepth = 256;

    private final Lexer lexer;
    public final List<String> errors = new ArrayList<>();
    public boolean aborted = false;
    public boolean constFolding = true;
    public int maxDepth = kDefaultMaxDepth;
    private Token cur = new Token();
    private Token peek = new Token();

    private static final class Prec {
        static final int lowest = 0, or_ = 1, and_ = 2, equals = 3, lessGreater = 4,
            addSub = 5, mulDiv = 6, pow = 7, prefix = 8, paren = 9;
    }

    private static int binopPrec(int t) {
        return switch (t) {
            case TokenType.Or -> Prec.or_;
            case TokenType.And -> Prec.and_;
            case TokenType.EQ, TokenType.NE -> Prec.equals;
            case TokenType.LT, TokenType.LE, TokenType.GT, TokenType.GE -> Prec.lessGreater;
            case TokenType.Add, TokenType.Sub -> Prec.addSub;
            case TokenType.Mul, TokenType.Div, TokenType.IDiv, TokenType.Mod -> Prec.mulDiv;
            case TokenType.Pow -> Prec.pow;
            case TokenType.LParen, TokenType.LBrack -> Prec.paren;
            default -> Prec.lowest;
        };
    }

    private static boolean isInfix(int t) {
        return switch (t) {
            case TokenType.Or, TokenType.And, TokenType.EQ, TokenType.NE, TokenType.LT,
                 TokenType.LE, TokenType.GT, TokenType.GE, TokenType.Add, TokenType.Sub,
                 TokenType.Mul, TokenType.Div, TokenType.IDiv, TokenType.Mod, TokenType.Pow,
                 TokenType.LParen, TokenType.LBrack -> true;
            default -> false;
        };
    }

    public Parser(Lexer lx) {
        this.lexer = lx;
        nextToken();
        nextToken();
    }

    private void nextToken() { cur = peek; peek = lexer.nextToken(); }
    private Expr optimize(Expr e) { return constFolding ? ExprOptim.optimize(e) : e; }
    private void addError(int line, String msg) {
        if (aborted) return;
        errors.add("line " + line + ": " + msg);
    }
    private void abortTooDeep(int line) {
        addError(line, "nesting too deep (max " + maxDepth + "). ");
        aborted = true;
    }

    // ------------------------------------------------------------------ prog
    public void parseProgram(Prog prog) { parseProg(prog, true, 1); }

    private void parseProg(Prog prog, boolean isTop, int depth) {
        if (aborted) return;
        while (!aborted && cur.typ != TokenType.Eof) {
            if (cur.typ == TokenType.RBrace) {
                if (!isTop) break;
                addError(cur.line, "unexpected \"}\" at top level. ");
                nextToken();
                continue;
            }
            if (cur.typ == TokenType.Semi) { nextToken(); continue; }
            Stmt stmt = parseStmtDispatch(depth);
            if (stmt == null) break;
            prog.stmts.add(stmt);
        }
    }

    // ------------------------------------------------------------------ 语句
    private Stmt parseLetStmt(int depth) {
        int line = cur.line;
        List<String> idents = new ArrayList<>();
        boolean hasAssign = false;
        Expr expr = null;
        nextToken();
        if (cur.typ != TokenType.Ident) {
            addError(cur.line, "expected identifier after \"let\". ");
            nextToken();
            return new LetStmt(line, idents, false, null);
        }
        idents.add(cur.parsed);
        nextToken();
        if (cur.typ == TokenType.Semi) nextToken();
        else if (cur.typ == TokenType.Comma) {
            while (true) {
                if (cur.typ == TokenType.Comma && peek.typ == TokenType.Ident) {
                    idents.add(peek.parsed);
                    nextToken(); nextToken();
                } else if (cur.typ == TokenType.Semi) { nextToken(); break; }
                else if (cur.typ == TokenType.Eof || cur.typ == TokenType.RBrace) {
                    addError(cur.line, "expected \";\" in let statement. "); break;
                } else { addError(cur.line, "failed to parse let statement with multiple identifiers. "); nextToken(); }
            }
        } else if (cur.typ == TokenType.Assign) {
            hasAssign = true;
            nextToken();
            expr = parseExpr(Prec.lowest, depth);
            nextToken();
        } else { addError(cur.line, "unexpected token in let statement. "); nextToken(); }
        return new LetStmt(line, idents, hasAssign, expr);
    }

    private Stmt parseExportStmt(int depth) {
        int line = cur.line;
        List<String> idents = new ArrayList<>();
        nextToken();
        if (cur.typ != TokenType.Ident) {
            addError(cur.line, "expected identifier after \"export\". ");
            nextToken();
            return new ExportStmt(line, idents);
        }
        idents.add(cur.parsed);
        nextToken();
        if (cur.typ == TokenType.Semi) nextToken();
        else if (cur.typ == TokenType.Comma) {
            while (true) {
                if (cur.typ == TokenType.Comma && peek.typ == TokenType.Ident) {
                    idents.add(peek.parsed); nextToken(); nextToken();
                } else if (cur.typ == TokenType.Semi) { nextToken(); break; }
                else if (cur.typ == TokenType.Eof || cur.typ == TokenType.RBrace) {
                    addError(cur.line, "expected \";\" in export statement. "); break;
                } else { addError(cur.line, "failed to parse export statement with multiple identifiers. "); nextToken(); }
            }
        } else { addError(cur.line, "unexpected token in export statement. "); nextToken(); }
        return new ExportStmt(line, idents);
    }

    private Stmt parseReturnStmt(int depth) {
        int line = cur.line;
        List<Expr> exprs = new ArrayList<>();
        nextToken();
        if (cur.typ == TokenType.Semi) { nextToken(); return new ReturnStmt(line, exprs); }
        if (cur.typ == TokenType.Eof || cur.typ == TokenType.RBrace) {
            addError(cur.line, "expected \";\" in return statement. ");
            return new ReturnStmt(line, exprs);
        }
        Expr e0 = parseExpr(Prec.lowest, depth);
        if (e0 != null) exprs.add(e0);
        nextToken();
        while (true) {
            if (cur.typ == TokenType.Semi) { nextToken(); break; }
            else if (cur.typ == TokenType.Comma) {
                nextToken();
                Expr e = parseExpr(Prec.lowest, depth);
                if (e != null) exprs.add(e);
                nextToken();
            } else { addError(cur.line, "expected \";\" or \",\" in return statement. "); nextToken(); break; }
        }
        return new ReturnStmt(line, exprs);
    }

    private Stmt parseBlockStmt(int depth) {
        if (aborted) return null;
        int line = cur.line;
        nextToken();
        Prog p = new Prog();
        parseProg(p, false, depth + 1);
        if (cur.typ != TokenType.RBrace) addError(cur.line, "expected \"}\" at end of block statement. ");
        nextToken();
        return new BlockStmt(line, p);
    }

    private Stmt parseIfStmt(int depth) {
        if (aborted) return null;
        int line = cur.line;
        Expr cond = parseExprAfterKeyword();
        if (cur.typ != TokenType.LBrace) {
            addError(cur.line, "expected \"{\" in if statement. ");
            return new IfStmt(line, cond, new Prog(), new ArrayList<>(), null);
        }
        nextToken();
        Prog first = new Prog();
        parseProg(first, false, depth + 1);
        if (cur.typ != TokenType.RBrace) {
            addError(cur.line, "expected \"}\" in if statement. ");
            return new IfStmt(line, cond, first, new ArrayList<>(), null);
        }
        nextToken();
        List<Elif> elifs = new ArrayList<>();
        Prog elseProg = null;
        while (cur.typ == TokenType.Elif) {
            nextToken();
            Expr ec = parseExpr(Prec.lowest, depth);
            nextToken();
            if (cur.typ != TokenType.LBrace) { addError(cur.line, "expected \"{\" of elif. "); break; }
            nextToken();
            Prog ep = new Prog();
            parseProg(ep, false, depth + 1);
            if (cur.typ != TokenType.RBrace) { addError(cur.line, "expected \"}\" of elif. "); break; }
            nextToken();
            elifs.add(new Elif(ec, ep));
        }
        if (cur.typ == TokenType.Else) {
            nextToken();
            if (cur.typ != TokenType.LBrace) addError(cur.line, "expected \"{\" after else. ");
            else {
                nextToken();
                Prog ep = new Prog();
                parseProg(ep, false, depth + 1);
                if (cur.typ != TokenType.RBrace) addError(cur.line, "expected \"}\" in if statement. ");
                nextToken();
                elseProg = ep;
            }
        }
        return new IfStmt(line, cond, first, elifs, elseProg);
    }

    private Expr parseExprAfterKeyword() {
        nextToken();
        Expr e = parseExpr(Prec.lowest, 2);
        nextToken();
        return e;
    }

    private Stmt parseWhileStmt(int depth) {
        if (aborted) return null;
        int line = cur.line;
        nextToken();
        Expr cond = null;
        if (cur.typ != TokenType.LBrace) { cond = parseExpr(Prec.lowest, depth); nextToken(); }
        if (cur.typ != TokenType.LBrace) {
            addError(cur.line, "expected \"{\" in while statement. ");
            return new WhileStmt(line, cond, new Prog());
        }
        nextToken();
        Prog p = new Prog();
        parseProg(p, false, depth + 1);
        if (cur.typ != TokenType.RBrace) addError(cur.line, "expected \"}\" at end of while statement. ");
        nextToken();
        return new WhileStmt(line, cond, p);
    }

    private Stmt parseBreakStmt() {
        int line = cur.line;
        nextToken();
        if (cur.typ != TokenType.Semi) addError(cur.line, "expected \";\" in break statement. ");
        else nextToken();
        return new BreakStmt(line);
    }
    private Stmt parseContinueStmt() {
        int line = cur.line;
        nextToken();
        if (cur.typ != TokenType.Semi) addError(cur.line, "expected \";\" in continue statement. ");
        else nextToken();
        return new ContinueStmt(line);
    }
    private Stmt parseDeferStmt(int depth) {
        if (aborted) return null;
        int line = cur.line;
        nextToken();
        if (cur.typ == TokenType.Semi || cur.typ == TokenType.RBrace || cur.typ == TokenType.Eof) {
            addError(cur.line, "expected statement after \"defer\". ");
            return new DeferStmt(line, null);
        }
        return new DeferStmt(line, parseStmtDispatch(depth + 1));
    }

    private Stmt parseStmtDispatch(int depth) {
        if (aborted) return null;
        return switch (cur.typ) {
            case TokenType.Let -> parseLetStmt(depth);
            case TokenType.Export -> parseExportStmt(depth);
            case TokenType.Return -> parseReturnStmt(depth);
            case TokenType.LBrace -> parseBlockStmt(depth);
            case TokenType.If -> parseIfStmt(depth);
            case TokenType.While -> parseWhileStmt(depth);
            case TokenType.Break -> parseBreakStmt();
            case TokenType.Continue -> parseContinueStmt();
            case TokenType.Defer -> parseDeferStmt(depth);
            default -> parseExprOrAssignStmt(depth);
        };
    }

    private Stmt parseExprOrAssignStmt(int depth) {
        Expr left = parseExpr(Prec.lowest, depth);
        if (left == null) return null;
        nextToken();
        if (cur.typ == TokenType.Semi) { nextToken(); return new ExprStmt(left.line, left); }
        else if (cur.typ == TokenType.Assign) {
            nextToken();
            Expr right = parseExpr(Prec.lowest, depth);
            nextToken();
            if (cur.typ != TokenType.Semi) addError(cur.line, "expected \";\" at end of assign statement. ");
            nextToken();
            if (right != null) return new AssignStmt(left.line, left, right);
            return null;
        }
        addError(cur.line, "expected \";\" or \"=\". ");
        return new ExprStmt(left.line, left);
    }

    // ------------------------------------------------------------------ 表达式
    private Expr parseExpr(int precedence, int depth) {
        if (aborted) return null;
        if (maxDepth > 0 && depth > maxDepth) { abortTooDeep(cur.line); return null; }
        Expr left = parsePrefix(depth);
        if (left == null) return null;
        while (!aborted && peek.typ != TokenType.Semi && precedence < binopPrec(peek.typ)) {
            if (!isInfix(peek.typ)) { addError(peek.line, "no infix parse function for token type. "); return left; }
            nextToken();
            Expr next = parseInfix(left, depth);
            if (next == null) return null;
            left = next;
        }
        return left;
    }

    private Expr parsePrefix(int depth) {
        int line = cur.line;
        int t = cur.typ;
        switch (t) {
            case TokenType.Ident: return new IdentExpr(line, cur.parsed);
            case TokenType.Null: return new NullExpr(line);
            case TokenType.False_: case TokenType.True_: return new BoolExpr(line, t == TokenType.True_);
            case TokenType.Integer: return new IntExpr(line, (Long) cur.value);
            case TokenType.Float: return new FloatExpr(line, (Double) cur.value);
            case TokenType.String: return new StringExpr(line, cur.parsed);
            case TokenType.BinArr: {
                String bytes = BinArrParser.parse(cur.lexeme);
                if (bytes == null) { addError(line, "invalid binary array. "); return new BinArrExpr(line, ""); }
                return new BinArrExpr(line, bytes);
            }
            case TokenType.Argc: return new ArgcExpr(line);
            case TokenType.Sub: case TokenType.Not: {
                int op = t;
                nextToken();
                Expr inner = parseExpr(Prec.prefix, depth + 1);
                if (inner == null) return null;
                return optimize(new UnaryExpr(line, op, inner));
            }
            case TokenType.LParen: {
                nextToken();
                Expr e = parseExpr(Prec.lowest, depth + 1);
                nextToken();
                if (cur.typ != TokenType.RParen) addError(cur.line, "expected \")\". ");
                return e;
            }
            case TokenType.Custom: return parseCustomExpr(line, depth);
            case TokenType.Args: return parseArgsExpr(line, depth);
            default: addError(line, "no prefix parse function for token type. "); return new ErrExpr(line);
        }
    }

    private Expr parseCustomExpr(int line, int depth) {
        String name = cur.parsed;
        List<Expr> args = new ArrayList<>();
        nextToken();
        if (cur.typ != TokenType.LParen) {
            addError(cur.line, "expected \"(\" after custom opcode. ");
            nextToken();
            return new CustomExpr(line, name, args);
        }
        nextToken();
        if (cur.typ == TokenType.RParen) { /* 空参数表 */ }
        else {
            Expr e0 = parseExpr(Prec.lowest, depth + 1);
            if (e0 != null) args.add(e0);
            while (peek.typ == TokenType.Comma) {
                nextToken(); nextToken();
                Expr e = parseExpr(Prec.lowest, depth + 1);
                if (e != null) args.add(e);
            }
            if (peek.typ != TokenType.RParen) addError(cur.line, "expected \")\". ");
            nextToken();
        }
        return new CustomExpr(line, name, args);
    }

    private Expr parseArgsExpr(int line, int depth) {
        if (peek.typ != TokenType.LBrack) {
            addError(peek.line, "expected \"[\" after \"args\". ");
            return new ArgsExpr(line, null);
        }
        nextToken(); nextToken();
        Expr key = parseExpr(Prec.lowest, depth + 1);
        nextToken();
        if (cur.typ != TokenType.RBrack) addError(cur.line, "expected \"]\". ");
        return new ArgsExpr(line, key);
    }

    private Expr parseInfix(Expr left, int depth) {
        int op = cur.typ;
        if (op == TokenType.LParen) return parseCallExpr(left, depth);
        if (op == TokenType.LBrack) return parseAtExpr(left, depth);
        int line = left.line;
        int prec = binopPrec(op);
        if (op == TokenType.Pow) prec -= 1; // ^ 右结合
        nextToken();
        Expr right = parseExpr(prec, depth + 1);
        if (right == null) return null;
        return optimize(new BinaryExpr(line, op, left, right));
    }

    private Expr parseCallExpr(Expr callee, int depth) {
        List<Expr> args = new ArrayList<>();
        if (peek.typ != TokenType.RParen) {
            nextToken();
            Expr e0 = parseExpr(Prec.lowest, depth + 1);
            if (e0 != null) args.add(e0);
            while (peek.typ == TokenType.Comma) {
                nextToken(); nextToken();
                Expr e = parseExpr(Prec.lowest, depth + 1);
                if (e != null) args.add(e);
            }
        }
        if (peek.typ == TokenType.RParen) nextToken();
        else addError(peek.line, "expected \")\". ");
        return new CallExpr(callee.line, callee, args);
    }

    private Expr parseAtExpr(Expr container, int depth) {
        List<Expr> keys = new ArrayList<>();
        if (peek.typ != TokenType.RBrack) {
            nextToken();
            Expr e0 = parseExpr(Prec.lowest, depth + 1);
            if (e0 != null) keys.add(e0);
            while (peek.typ == TokenType.Comma) {
                nextToken(); nextToken();
                Expr e = parseExpr(Prec.lowest, depth + 1);
                if (e != null) keys.add(e);
            }
        }
        if (peek.typ == TokenType.RBrack) nextToken();
        else addError(peek.line, "expected \"]\". ");
        return new AtExpr(container.line, container, keys);
    }
}
