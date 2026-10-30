using System;
using System.Collections.Generic;

namespace Stope;

/// <summary>
/// 语法分析器（Pratt）—— 端口 <c>cpp/src/parser.cpp</c>（C++ 为权威实现）。
/// <para>行为契约见 <c>docs/zh-cn/parser-test-plan.md</c>。几条容易踩错、且各实现必须一致的约定：</para>
/// <list type="number">
/// <item>错误恢复：<b>分隔符缺失时只报错、不推进</b>，把后续 token 留给下一条语句重新解析。
/// 例外（有意保留旧语义）：<c>ParseLetStmt</c> / <c>ParseReturnStmt</c> 的兜底分支仍会推进。</item>
/// <item>不变量：<c>ParseExpr()</c> 之后必有一次 <c>NextToken()</c>。删错误分支里的推进时别连带删它。</item>
/// <item>顶层孤立 <c>}</c> 要报错<b>并跳过</b>继续解析；块内的 <c>}</c> 由外层消费，不报错。</item>
/// <item>常量折叠挂在 <c>ParseUnaryOpExpr</c> / <c>ParseBinaryOpExpr</c> 的构造末尾，
/// <b>不要</b>改成把 <c>ParseExpr</c> 包一层 —— 那样每层递归多一个栈帧，深括号用例会崩。</item>
/// <item>节点取 token 的 <see cref="Token.Parsed"/> 而非 <see cref="Token.Lexeme"/>：
/// 字符串要转义后的值、标识符要拼好的 <c>:</c>。只有 BinArr 取 lexeme（词法阶段不做任何转义）。</item>
/// </list>
/// </summary>
public sealed class Parser
{
    /// <summary>嵌套深度上限的默认值（与 C++ 的 <c>Parser::maxDepth</c> 相同）。0 = 不限制。</summary>
    public const int DefaultMaxDepth = 256;

    private readonly BinArrParser _binArrParser = new();

    public readonly List<string> Errors = new();

    /// <summary>超限中止标记。置位之后 <see cref="Error"/> 不再记账（否则会刷上万条连锁噪音）。</summary>
    private bool _aborted;

    public Lexer Lexer = null!;
    public CustomOpcodeConfig? Custom;

    /// <summary>是否做常量折叠（默认 true）。测试里关掉它才能看到未折叠的 AST。</summary>
    public bool ConstFolding = true;

    /// <summary>嵌套深度上限，0 = 不限制。</summary>
    public int MaxDepth = DefaultMaxDepth;

    private Token _cur = new(1, TokenType.Eof);
    private Token _peek = new(1, TokenType.Eof);

    public Parser(Lexer lexer, CustomOpcodeConfig? custom = null) => Reset(lexer, custom);

    /// <summary>与 C++ 的 <c>Parser::Reset</c> 一致：清错误、重挂词法器、重读两个 token。</summary>
    public void Reset(Lexer lexer, CustomOpcodeConfig? custom = null)
    {
        Errors.Clear();
        _aborted = false;
        Lexer = lexer;
        Custom = custom;
        ConstFolding = true;
        MaxDepth = DefaultMaxDepth;
        // 先读两个 token，cur / peek 才都有值 —— 顺序不能变，
        // 否则输入最开头的自定义指令或首个 token 会被漏掉。
        NextToken();
        NextToken();
    }

    public void ParseProgram(Prog prog) => ParseProg(prog, true, 1);

    // ================================ 语句 ================================
    /// <summary>
    /// <paramref name="isTopLevel"/> = true 只有 <see cref="ParseProgram"/> 用。块 / if / while
    /// 内部的 prog 都是 false：它们的 <c>}</c> 属于外层语句，必须由外层自己消费。
    /// </summary>
    private void ParseProg(Prog prog, bool isTopLevel, int depth)
    {
        if (_aborted) return;
        while (!_aborted && _cur.Type != TokenType.Eof)
        {
            if (_cur.Type == TokenType.RBrace)
            {
                if (!isTopLevel) break; // 块内：正常结束，不跳过，交给外层处理
                Error(_cur.Line, "unexpected \"}\" at top level. ");
                NextToken();
                continue;
            }
            if (_cur.Type == TokenType.Semi)
            { // 空语句
                NextToken();
                continue;
            }

            Stmt? stmt;
            switch (_cur.Type)
            {
                case TokenType.Let: stmt = ParseLetStmt(depth); break;
                case TokenType.Export: stmt = ParseExportStmt(depth); break;
                case TokenType.Return: stmt = ParseReturnStmt(depth); break;
                case TokenType.LBrace: stmt = ParseBlockStmt(depth); break;
                case TokenType.If: stmt = ParseIfStmt(depth); break;
                case TokenType.While: stmt = ParseWhileStmt(depth); break;
                case TokenType.Break: stmt = ParseBreakStmt(depth); break;
                case TokenType.Continue: stmt = ParseContinueStmt(depth); break;
                default: stmt = ParseExprOrAssignStmt(depth); break; // 表达式语句或赋值语句
            }
            // 超限中止时子函数返回 null：不追加、不再往下解析（否则拿着同一个
            // token 反复调用会死循环）。
            if (stmt is null) break;
            prog.Stmts.Add(stmt);
        }
    }

    private LetStmt ParseLetStmt(int depth)
    {
        var stmt = new LetStmt(_cur.Line) { HasAssign = false };
        NextToken(); // 跳过 let
        if (_cur.Type != TokenType.Ident)
        {
            Error(_cur.Line, "expected identifier after \"let\". ");
            NextToken();
            return stmt;
        }
        stmt.Idents.Add(_cur.Parsed);
        NextToken();
        if (_cur.Type == TokenType.Semi)
        {
            // 单个标识符且不赋值
            NextToken();
        }
        else if (_cur.Type == TokenType.Comma)
        {
            // 多个标识符，禁止赋值
            for (;;)
            {
                if (_cur.Type == TokenType.Comma && _peek.Type == TokenType.Ident)
                {
                    stmt.Idents.Add(_peek.Parsed);
                    NextToken();
                    NextToken();
                }
                else if (_cur.Type == TokenType.Semi)
                {
                    NextToken();
                    break;
                }
                else if (_cur.Type is TokenType.Eof or TokenType.RBrace)
                {
                    // 缺 ";"：此处不能再推进。Eof 上推进不会前进会死循环，
                    // 推进又会吞掉外层块的 "}" 导致解析错位。
                    Error(_cur.Line, "expected \";\" in let statement. ");
                    break;
                }
                else
                {
                    Error(_cur.Line, "failed to parse let statement with multiple identifiers. ");
                    NextToken();
                }
            }
        }
        else if (_cur.Type == TokenType.Assign)
        {
            stmt.HasAssign = true;
            NextToken();
            stmt.Expr = ParseExpr(Precedence.Lowest, depth);
            NextToken();
        }
        else
        {
            Error(_cur.Line, "unexpected token in let statement. ");
            NextToken();
        }
        return stmt;
    }

    private ExportStmt ParseExportStmt(int depth)
    {
        _ = depth;
        var stmt = new ExportStmt(_cur.Line);
        NextToken(); // 跳过 export
        if (_cur.Type != TokenType.Ident)
        {
            Error(_cur.Line, "expected identifier after \"export\". ");
            NextToken();
            return stmt;
        }
        stmt.Idents.Add(_cur.Parsed);
        NextToken();
        if (_cur.Type == TokenType.Semi)
        {
            NextToken();
        }
        else if (_cur.Type == TokenType.Comma)
        {
            for (;;)
            {
                if (_cur.Type == TokenType.Comma && _peek.Type == TokenType.Ident)
                {
                    stmt.Idents.Add(_peek.Parsed);
                    NextToken();
                    NextToken();
                }
                else if (_cur.Type == TokenType.Semi)
                {
                    NextToken();
                    break;
                }
                else if (_cur.Type is TokenType.Eof or TokenType.RBrace)
                {
                    Error(_cur.Line, "expected \";\" in export statement. ");
                    break;
                }
                else
                {
                    Error(_cur.Line, "failed to parse export statement with multiple identifiers. ");
                    NextToken();
                }
            }
        }
        else
        {
            Error(_cur.Line, "unexpected token in export statement. ");
            NextToken();
        }
        return stmt;
    }

    /// <summary><c>return_stmt : "return" ( expr ( "," expr )* )? ";"</c></summary>
    private ReturnStmt ParseReturnStmt(int depth)
    {
        var stmt = new ReturnStmt(_cur.Line);
        NextToken(); // 跳过 return
        if (_cur.Type == TokenType.Semi)
        {
            // 无返回值，exprs 为空
            NextToken();
            return stmt;
        }
        if (_cur.Type is TokenType.Eof or TokenType.RBrace)
        {
            // 缺 ";"：此时不能吞掉 } 或 Eof，否则外层块会解析错位
            Error(_cur.Line, "expected \";\" in return statement. ");
            return stmt;
        }
        var first = ParseExpr(Precedence.Lowest, depth);
        if (first is not null) stmt.Exprs.Add(first); // 第一个表达式
        NextToken(); // 到达 , 或 ;
        for (;;)
        {
            // ("," expr)*
            if (_cur.Type == TokenType.Semi)
            {
                NextToken();
                break;
            }
            if (_cur.Type == TokenType.Comma)
            {
                NextToken();
                var e = ParseExpr(Precedence.Lowest, depth);
                if (e is not null) stmt.Exprs.Add(e);
                NextToken();
            }
            else
            {
                Error(_cur.Line, "expected \";\" or \",\" in return statement. ");
                NextToken();
                break;
            }
        }
        return stmt;
    }

    private BlockStmt? ParseBlockStmt(int depth)
    {
        if (_aborted) return null; // 已超限：不再解析
        var stmt = new BlockStmt(_cur.Line);
        NextToken(); // 跳过 {
        stmt.Prog = new Prog();
        ParseProg(stmt.Prog, false, depth + 1);
        if (_cur.Type != TokenType.RBrace) Error(_cur.Line, "expected \"}\" at end of block statement. ");
        NextToken(); // 跳过 }
        return stmt;
    }

    /// <summary><c>if_stmt : "if" expr "{" prog "}" ("elif" expr "{" prog "}")* ("else" "{" prog "}")?</c></summary>
    private IfStmt? ParseIfStmt(int depth)
    {
        if (_aborted) return null;
        var stmt = new IfStmt(_cur.Line);
        NextToken(); // 跳过 if
        stmt.Cond = ParseExpr(Precedence.Lowest, depth);
        NextToken(); // 到达 {
        if (_cur.Type != TokenType.LBrace)
        {
            Error(_cur.Line, "expected \"{\" in if statement. ");
            return stmt;
        }
        NextToken(); // 跳过 {
        stmt.FirstProg = new Prog();
        ParseProg(stmt.FirstProg, false, depth + 1);
        if (_cur.Type != TokenType.RBrace)
        {
            Error(_cur.Line, "expected \"}\" in if statement. ");
            return stmt;
        }
        NextToken(); // 跳过 }
        while (_cur.Type == TokenType.Elif)
        {
            // ("elif" expr "{" prog "}")*
            var ei = new IfStmtElif(_cur.Line);
            NextToken(); // 跳过 elif
            ei.Cond = ParseExpr(Precedence.Lowest, depth);
            NextToken();
            if (_cur.Type != TokenType.LBrace)
            {
                Error(_cur.Line, "expected \"{\" of elif. ");
                return stmt;
            }
            NextToken(); // 跳过 {
            ei.Prog = new Prog();
            ParseProg(ei.Prog, false, depth + 1);
            if (_cur.Type != TokenType.RBrace)
            {
                Error(_cur.Line, "expected \"}\" of elif. ");
                return stmt;
            }
            NextToken(); // 跳过 }
            stmt.Elifs.Add(ei);
        }
        if (_cur.Type == TokenType.Else)
        {
            NextToken();
            if (_cur.Type != TokenType.LBrace)
            {
                Error(_cur.Line, "expected \"{\" after else. ");
                return stmt;
            }
            NextToken(); // 跳过 {
            stmt.ElseProg = new Prog();
            ParseProg(stmt.ElseProg, false, depth + 1);
            if (_cur.Type != TokenType.RBrace)
            {
                Error(_cur.Line, "expected \"}\" in if statement. ");
                return stmt;
            }
            NextToken(); // 跳过 }
        }
        return stmt;
    }

    /// <summary><c>while_stmt : "while" expr? "{" prog "}"</c></summary>
    private WhileStmt? ParseWhileStmt(int depth)
    {
        if (_aborted) return null;
        var stmt = new WhileStmt(_cur.Line);
        NextToken(); // 跳过 while
        if (_cur.Type != TokenType.LBrace)
        {
            stmt.Cond = ParseExpr(Precedence.Lowest, depth);
            NextToken(); // 到达 {
        }
        if (_cur.Type != TokenType.LBrace)
        {
            Error(_cur.Line, "expected \"{\" in while statement. ");
            return stmt;
        }
        NextToken(); // 跳过 {
        stmt.Prog = new Prog();
        ParseProg(stmt.Prog, false, depth + 1);
        if (_cur.Type != TokenType.RBrace)
        {
            Error(_cur.Line, "expected \"}\" at end of while statement. ");
            return stmt;
        }
        NextToken();
        return stmt;
    }

    private BreakStmt ParseBreakStmt(int depth)
    {
        _ = depth;
        var stmt = new BreakStmt(_cur.Line);
        NextToken(); // 跳过 break
        if (_cur.Type != TokenType.Semi) Error(_cur.Line, "expected \";\" in break statement. ");
        else NextToken();
        return stmt;
    }

    private ContinueStmt ParseContinueStmt(int depth)
    {
        _ = depth;
        var stmt = new ContinueStmt(_cur.Line);
        NextToken(); // 跳过 continue
        if (_cur.Type != TokenType.Semi) Error(_cur.Line, "expected \";\" in continue statement. ");
        else NextToken();
        return stmt;
    }

    private Stmt? ParseExprOrAssignStmt(int depth)
    {
        var leftExpr = ParseExpr(Precedence.Lowest, depth);
        if (leftExpr is null) return null; // 超限中止：下面要读 leftExpr.Line
        NextToken(); // 到达 = 或 ;
        if (_cur.Type == TokenType.Semi)
        {
            NextToken(); // 跳过 ;
            return new ExprStmt(leftExpr.Line) { Expr = leftExpr };
        }
        if (_cur.Type == TokenType.Assign)
        {
            NextToken(); // 跳过 =
            var a = new AssignStmt(leftExpr.Line) { LeftExpr = leftExpr };
            a.RightExpr = ParseExpr(Precedence.Lowest, depth);
            NextToken(); // 到达 ;
            if (_cur.Type != TokenType.Semi) Error(_cur.Line, "expected \";\" at end of assign statement. ");
            NextToken();
            return a;
        }
        Error(_cur.Line, "expected \";\" or \"=\". ");
        // 不推进：当前 token 不是合法的语句边界，留给下一轮语句解析。
        // 否则会吞掉后续语句（f(1, 2 x; y; 里的 x; 被吞）。
        return new ExprStmt(leftExpr.Line) { Expr = leftExpr };
    }

    // ================================ 表达式主循环 ================================
    private Expr? ParseExpr(Precedence precedence, int depth)
    {
        // 深度检查只在这里和 ParseProg 做 —— 只有这两处会递归。
        if (_aborted) return null;
        if (MaxDepth > 0 && depth > MaxDepth)
        {
            AbortTooDeep(_cur.Line);
            return null;
        }

        if (!PrefixFns.TryGetValue(_cur.Type, out var prefix))
        {
            Error(_cur.Line, "no prefix parse function for token type. ");
            return new ErrorExpr(_cur.Line); // 失败路径返回裸节点，形状为 Err(L行号)
        }
        var leftExpr = prefix(this, depth);
        if (leftExpr is null) return null; // 子表达式已中止（括号会原样透出）

        while (!_aborted && _peek.Type != TokenType.Semi && precedence < PeekPrecedence())
        {
            if (!InfixFns.TryGetValue(_peek.Type, out var infix))
            {
                Error(_peek.Line, "no infix parse function for token type. ");
                return leftExpr;
            }
            NextToken();
            leftExpr = infix(this, leftExpr, depth);
            if (leftExpr is null) return null;
        }
        return leftExpr;
    }

    private Precedence CurPrecedence() => TokenText.PrecOf(_cur.Type);

    private Precedence PeekPrecedence() => TokenText.PrecOf(_peek.Type);

    /// <summary>
    /// 常量折叠的单一入口。挂在 <c>ParseUnaryOpExpr</c> / <c>ParseBinaryOpExpr</c> 的
    /// 构造末尾（见那两处），<b>不要</b>改成把 <see cref="ParseExpr"/> 包一层。
    /// </summary>
    private Expr? OptimizeInPlace(Expr? e)
    {
        if (!ConstFolding) return e;
        return ExprOptim.Optimize(e);
    }

    // ================================ 基础设施 ================================
    public void NextToken()
    {
        _cur = _peek;
        _peek = Lexer.NextToken(Custom);
    }

    public Token CurToken => _cur;

    public Token PeekToken => _peek;

    public void Error(int line, string msg)
    {
        // 嵌套超限中止之后的一切错误（缺 "}"、expected ")" 之类）都是连锁反应，
        // 不再记账 —— 否则一个 12000 层的块嵌套能刷出上万条噪音。
        if (_aborted) return;
        Errors.Add("line " + line + ": " + msg);
    }

    private void AbortTooDeep(int line)
    {
        Error(line, "nesting too deep (max " + MaxDepth + "). "); // 必须在置位之前记账
        _aborted = true;
    }

    public bool HasError() => Errors.Count > 0;

    // ================================ 前缀 ================================
    private static Expr ParseIdentExpr(Parser p, int depth)
    {
        _ = depth;
        return new IdentExpr(p._cur.Line, p._cur.Parsed);
    }

    private static Expr ParseNullExpr(Parser p, int depth)
    {
        _ = depth;
        return new NullExpr(p._cur.Line);
    }

    private static Expr ParseBoolExpr(Parser p, int depth)
    {
        _ = depth;
        return new BoolExpr(p._cur.Line, p._cur.Type == TokenType.True);
    }

    private static Expr ParseIntExpr(Parser p, int depth)
    {
        _ = depth;
        return new IntExpr(p._cur.Line, p._cur.IntValue);
    }

    private static Expr ParseFloatExpr(Parser p, int depth)
    {
        _ = depth;
        return new FloatExpr(p._cur.Line, p._cur.FloatValue);
    }

    /// <summary>取 parsed：转义已完成（lexeme 是未转义的原文）。</summary>
    private static Expr ParseStringExpr(Parser p, int depth)
    {
        _ = depth;
        return new StringExpr(p._cur.Line, p._cur.Parsed);
    }

    private static Expr ParseBinArrExpr(Parser p, int depth)
    {
        _ = depth;
        var e = new BinArrExpr(p._cur.Line);
        // 取 lexeme：二进制数组不做转义，解析到一半失败也要保留前半段（报错但继续）
        var bytes = new List<byte>();
        var rc = p._binArrParser.Parse(p._cur.Lexeme, bytes);
        e.Value = bytes.ToArray();
        if (rc != Result.Success) p.Error(p._cur.Line, "invalid binary array. ");
        return e;
    }

    private static Expr ParseArgcExpr(Parser p, int depth)
    {
        _ = depth;
        return new ArgcExpr(p._cur.Line);
    }

    private static Expr? ParseUnaryOpExpr(Parser p, int depth)
    {
        var e = new UnaryOpExpr(p._cur.Line) { Op = p._cur.Type };
        p.NextToken();
        e.Expr = p.ParseExpr(Precedence.Prefix, depth + 1);
        return p.OptimizeInPlace(e); // 自底向上：子表达式已折好，这里折自己
    }

    private static Expr? ParseParenExpr(Parser p, int depth)
    {
        p.NextToken();
        var e = p.ParseExpr(Precedence.Lowest, depth + 1);
        p.NextToken();
        if (p._cur.Type != TokenType.RParen) p.Error(p._cur.Line, "expected \")\". ");
        return e; // 停在 )
    }

    private static Expr ParseCustomOpcodeExpr(Parser p, int depth)
    {
        var e = new CustomOpcodeExpr(p._cur.Line) { OpcodeName = p._cur.Parsed };
        p.NextToken(); // 到达 (
        if (p._cur.Type != TokenType.LParen)
        {
            p.Error(p._cur.Line, "expected \"(\" after custom opcode. ");
            p.NextToken();
            return e;
        }
        p.NextToken();
        if (p._cur.Type == TokenType.RParen)
        {
            // 空参数表，cur 停在 )
        }
        else
        {
            // expr ("," expr)*
            var a0 = p.ParseExpr(Precedence.Lowest, depth + 1);
            if (a0 is not null) e.Args.Add(a0);
            while (p._peek.Type == TokenType.Comma)
            {
                p.NextToken();
                p.NextToken();
                var a = p.ParseExpr(Precedence.Lowest, depth + 1);
                if (a is not null) e.Args.Add(a);
            }
            if (p._peek.Type != TokenType.RParen) p.Error(p._cur.Line, "expected \")\". ");
            p.NextToken(); // 到达 )
        }
        return e;
    }

    private static Expr ParseArgsExpr(Parser p, int depth)
    {
        var e = new ArgsExpr(p._cur.Line);
        if (p._peek.Type != TokenType.LBrack)
        {
            // 不推进（cur 停在 "args"）：把后续 token 留给下一条语句，避免吞掉
            p.Error(p._peek.Line, "expected \"[\" after \"args\". ");
            return e;
        }
        p.NextToken(); // 到达 [
        p.NextToken();
        e.KeyExpr = p.ParseExpr(Precedence.Lowest, depth + 1);
        p.NextToken();
        if (p._cur.Type != TokenType.RBrack) p.Error(p._cur.Line, "expected \"]\". ");
        return e;
    }

    // ================================ 中缀 ================================
    private static Expr? ParseBinaryOpExpr(Parser p, Expr leftExpr, int depth)
    {
        var e = new BinaryOpExpr(leftExpr.Line) { LeftExpr = leftExpr, Op = p._cur.Type };
        var prec = p.CurPrecedence();
        // ^ 右结合：优先级 -1 让右侧继续吃同级的 ^（2^3^2 = 2^(3^2)）。
        if (e.Op == TokenType.Pow) prec -= 1;
        p.NextToken();
        e.RightExpr = p.ParseExpr(prec, depth + 1);
        return p.OptimizeInPlace(e); // 两侧都已折好，折叠只在最深的节点先发生
    }

    private static Expr? ParseCallExpr(Parser p, Expr callee, int depth)
    {
        var e = new CallExpr(callee.Line) { Callee = callee };
        // 外层已保证此处是 (
        if (p._peek.Type != TokenType.RParen)
        {
            // expr ("," expr)*
            p.NextToken(); // 到达第一个表达式
            var a0 = p.ParseExpr(Precedence.Lowest, depth + 1);
            if (a0 is not null) e.Args.Add(a0);
            while (p._peek.Type == TokenType.Comma)
            {
                p.NextToken(); // 到达 ","
                p.NextToken(); // 到达下一个表达式
                var a = p.ParseExpr(Precedence.Lowest, depth + 1);
                if (a is not null) e.Args.Add(a);
            }
        }
        if (p._peek.Type == TokenType.RParen)
        {
            p.NextToken(); // 跳过 )
        }
        else
        {
            // 缺 ")" 时不推进，避免吞掉后面的 token
            p.Error(p._peek.Line, "expected \")\". ");
        }
        return e;
    }

    private static Expr? ParseAtExpr(Parser p, Expr container, int depth)
    {
        var e = new AtExpr(container.Line) { Container = container };
        if (p._peek.Type != TokenType.RBrack)
        {
            // expr ("," expr)*
            p.NextToken(); // 到达第一个表达式
            var k0 = p.ParseExpr(Precedence.Lowest, depth + 1);
            if (k0 is not null) e.KeyExprs.Add(k0);
            while (p._peek.Type == TokenType.Comma)
            {
                p.NextToken(); // 到达 ","
                p.NextToken(); // 到达下一个表达式
                var k = p.ParseExpr(Precedence.Lowest, depth + 1);
                if (k is not null) e.KeyExprs.Add(k);
            }
        }
        if (p._peek.Type == TokenType.RBrack)
        {
            p.NextToken(); // 跳过 ]
        }
        else
        {
            // 缺 "]" 时不推进，避免吞掉后面的 token
            p.Error(p._peek.Line, "expected \"]\". ");
        }
        return e;
    }

    // ---------------- 分发表 ----------------
    private delegate Expr? PrefixFn(Parser p, int depth);

    private delegate Expr? InfixFn(Parser p, Expr left, int depth);

    private static readonly Dictionary<TokenType, PrefixFn> PrefixFns = new()
    {
        [TokenType.Ident] = ParseIdentExpr,
        [TokenType.Null] = ParseNullExpr,
        [TokenType.False] = ParseBoolExpr,
        [TokenType.True] = ParseBoolExpr,
        [TokenType.Integer] = ParseIntExpr,
        [TokenType.Float] = ParseFloatExpr,
        [TokenType.String] = ParseStringExpr,
        [TokenType.BinArr] = ParseBinArrExpr,
        [TokenType.Argc] = ParseArgcExpr,
        [TokenType.Sub] = ParseUnaryOpExpr,
        [TokenType.Not] = ParseUnaryOpExpr,
        [TokenType.LParen] = ParseParenExpr,
        [TokenType.Custom] = ParseCustomOpcodeExpr,
        [TokenType.Args] = ParseArgsExpr,
    };

    private static readonly Dictionary<TokenType, InfixFn> InfixFns = new()
    {
        [TokenType.Or] = ParseBinaryOpExpr,
        [TokenType.And] = ParseBinaryOpExpr,
        [TokenType.EQ] = ParseBinaryOpExpr,
        [TokenType.NE] = ParseBinaryOpExpr,
        [TokenType.LT] = ParseBinaryOpExpr,
        [TokenType.LE] = ParseBinaryOpExpr,
        [TokenType.GT] = ParseBinaryOpExpr,
        [TokenType.GE] = ParseBinaryOpExpr,
        [TokenType.Add] = ParseBinaryOpExpr,
        [TokenType.Sub] = ParseBinaryOpExpr,
        [TokenType.Mul] = ParseBinaryOpExpr,
        [TokenType.Div] = ParseBinaryOpExpr,
        [TokenType.IDiv] = ParseBinaryOpExpr,
        [TokenType.Mod] = ParseBinaryOpExpr,
        [TokenType.Pow] = ParseBinaryOpExpr,
        [TokenType.LParen] = ParseCallExpr, // () 函数调用
        [TokenType.LBrack] = ParseAtExpr,   // [] 取元素
    };
}
