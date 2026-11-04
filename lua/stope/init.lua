-- init.lua —— Stope 的 Lua 实现：聚合导出。分层与另外五套实现一一对应。
--
-- 标准层：Lexer / Parser / AST / expr_optim / Compiler / Program / BinaryArrayParser /
--         disasm / STML 三件套 —— 名字与 C++ 逐项对应。
-- 示例层：Api / State / Arguments / Identifier —— **不是标准**。

local stope = {}

stope.version = "0.1.0" -- 六处落点之一，改这里要一并改另外五处

stope.common = require("stope.common")
stope.utf = require("stope.utf")
stope.token = require("stope.token")
stope.lexer = require("stope.lexer")
stope.ast = require("stope.ast")
stope.expr_optim = require("stope.expr_optim")
stope.parser = require("stope.parser")
stope.binarr_parser = require("stope.binarr_parser")
stope.opcode = require("stope.opcode")
stope.program = require("stope.program")
stope.compiler = require("stope.compiler")
stope.disasm = require("stope.disasm")
stope.basic_vm = require("stope.basic_vm")
stope.stml = require("stope.stml")
stope.stml_lexer = require("stope.stml_lexer")
stope.stml_parser = require("stope.stml_parser")

local common = stope.common

-- 常用名字直接挂到顶层（对照 python/stope/__init__.py 的 __all__）
stope.Lexer = stope.lexer
stope.Parser = stope.parser
stope.AST = stope.ast
stope.ASTVisitor = nil -- Lua 版编译器自带分发，见 compiler.lua 的 VISIT_MAP
stope.Compiler = stope.compiler
stope.Program = stope.program
stope.BinaryArrayParser = stope.binarr_parser
stope.disasm = stope.disasm.disasm
stope.disasm_no_custom = require("stope.disasm").disasm_no_custom
stope.opcode = stope.opcode
stope.optimize = stope.expr_optim.optimize
stope.Result = common.Result
stope.esc = common.esc_u16
stope.esc8 = common.esc_u8
stope.fmt_g = common.fmt_g
stope.fmt_bytes = common.fmt_bytes
stope.TokenType = stope.token.TokenType
stope.type_name = stope.token.type_name

-- STML（带 Stml 前缀，免得与 Stope 的 Lexer / Parser / Token 撞名）
stope.StmlElement = stope.stml.Element
stope.StmlLexer = stope.stml_lexer
stope.StmlParser = stope.stml_parser.Parser
stope.StmlState = stope.stml.LexerState
stope.StmlTokenType = stope.stml.TokenType
stope.StmlToken = stope.stml.new_token
stope.stml_type_name = stope.stml.type_name

-- 示例层（不是标准）
stope.Api = stope.basic_vm.Api
stope.State = stope.basic_vm.State
stope.Arguments = stope.basic_vm.Arguments
stope.Identifier = stope.basic_vm.Identifier
stope.NULL = stope.basic_vm.NULL
stope.str_value = stope.basic_vm.str_value
stope.str_bytes = stope.basic_vm.str_bytes
stope.is_str_value = stope.basic_vm.is_str_value

return stope
