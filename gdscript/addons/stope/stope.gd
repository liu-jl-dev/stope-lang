# Stope GDScript 实现的统一入口。
#
# 本目录所有脚本（含本文件）都【不注册 class_name 全局类】，避免占用工程的全局类
# 命名空间、与其他插件或项目代码撞名。使用方一行 preload 引入本文件，再按
# Stope.模块 访问各组件：
#
#   const Stope = preload("res://addons/stope/stope.gd")
#
#   var lexer := Stope.Lexer.Lexer.new(SRC)
#   var parser := Stope.Parser.Parser.new(lexer)
#   ...
#   if rc != Stope.Result.Success: ...
#
# 组件与文件的对应关系（原名 = 重构前的全局类名）：
#
#   Result      stope_result.gd   跨模块共用返回码（对齐 C++ Stope::Result）   [原 StopeResult]
#   Opcode      opcode.gd         指令集（33 条内置 + 自定义指令登记）         [原 StopeOpcode]
#   Lexer       lexer.gd          Token 类型 + 词法分析                        [原 StopeLexer]
#   Ast         ast.gd            AST 节点定义 + 形状串序列化                  [原 StopeAst]
#   ASTVisitor  ast_visitor.gd    遍历骨架（继承 .ASTVisitor 重写 on_visit_*） [原 StopeASTVisitor]
#   BinArrParser binarr_parser.gd '...' 内容的字节解析                         [原 StopeBinArrParser]
#   ExprOptim   expr_optim.gd     常量折叠                                     [原 StopeExprOptim]
#   Parser      parser.gd         语法分析                                     [原 StopeParser]
#   Compiler    compiler.gd       编译器（AST -> Program）                     [原 StopeCompiler]
#   Program     program.gd        Program 数据结构（to_map / to_json_string）  [原 StopeProgram]
#   Debug       debug.gd          Program 反汇编（disasm）                     [原 StopeDebug]
#   BasicVM     basic_vm.gd       参考执行器（非标准，见 docs/zh-cn/vm-guide.md）[原 StopeBasicVM]
#   STML        stml.gd           STML 公共类型（Element / Token）
#   STMLLexer   stml_lexer.gd     STML 词法
#   STMLParser  stml_parser.gd    STML 语法
#
# 两条约束：
#   1. 各脚本之间的互相引用一律走 preload（编译期解析，与全局类一样没有运行时开销），
#      【不要】重新加回 class_name —— 那会重新污染全局命名空间，并重新引入对
#      .godot/global_script_class_cache.cfg 的依赖（删掉缓存就编译失败）。
#   2. 分发时把整个 addons/stope/ 目录拷进目标项目的 addons/ 下即可，无任何全局副作用。

const Result = preload("res://addons/stope/stope_result.gd")
const Opcode = preload("res://addons/stope/opcode.gd")
const Lexer = preload("res://addons/stope/lexer.gd")
const Ast = preload("res://addons/stope/ast.gd")
const ASTVisitor = preload("res://addons/stope/ast_visitor.gd")
const BinArrParser = preload("res://addons/stope/binarr_parser.gd")
const ExprOptim = preload("res://addons/stope/expr_optim.gd")
const Parser = preload("res://addons/stope/parser.gd")
const Compiler = preload("res://addons/stope/compiler.gd")
const Program = preload("res://addons/stope/program.gd")
const Debug = preload("res://addons/stope/debug.gd")
const BasicVM = preload("res://addons/stope/basic_vm.gd")
const STML = preload("res://addons/stope/stml.gd")
const STMLLexer = preload("res://addons/stope/stml_lexer.gd")
const STMLParser = preload("res://addons/stope/stml_parser.gd")
