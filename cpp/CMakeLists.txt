cmake_minimum_required(VERSION 3.10)

project(Stope)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(stope STATIC
    src/ast.cpp
    src/parse_binarr.cpp
    src/lexer.cpp
    src/expr_optim.cpp
    src/ast_visitor.cpp
    src/parser.cpp
    src/compiler.cpp
    src/stml_lexer.cpp
    src/stml_parser.cpp)
target_include_directories(stope PUBLIC include)
target_compile_features(stope PUBLIC cxx_std_20)

add_executable(demo01 demo/01-quick-start.cpp)
target_include_directories(demo01 PUBLIC include)
target_link_libraries(demo01 PRIVATE stope)

# 自定义指令：只编译 + 反汇编（DumpProgram + CustomOpcodeConfig），不接执行器。
add_executable(demo02 demo/02-custom-opcode.cpp)
target_include_directories(demo02 PUBLIC include)
target_link_libraries(demo02 PRIVATE stope)

# STML：解析一份内嵌标记文档，把里面的三种代码段原样切出来。
add_executable(demo03 demo/03-stml.cpp)
target_include_directories(demo03 PUBLIC include)
target_link_libraries(demo03 PRIVATE stope)

if(MSVC)
    add_compile_options(/utf-8)
endif()

enable_testing()

add_executable(test_lexer
    test/test_lexer.cpp
    test/test_lexer_number.cpp
    test/test_lexer_ident.cpp
    test/test_lexer_string.cpp
    test/test_lexer_punct.cpp
    test/test_lexer_flow.cpp
    test/test_lexer_misc.cpp
)
target_link_libraries(test_lexer PRIVATE stope)

add_test(NAME lexer COMMAND test_lexer)

# ---------------------------------------------------------------------------
# parser 测试：与 lexer 分开二进制。
# 原因：深嵌套用例（PD-13/PD-13b）会真的栈溢出崩溃，混进同一个二进制会连带
# lexer 的结论全部看不到；主二进制只跑"安全"的用例，崩溃阈值由
# test_parser_depth 以独立进程 + WILL_FAIL 登记。
add_executable(test_parser
    test/test_parser.cpp
    test/test_parser_stmt.cpp
    test/test_parser_expr.cpp
    test/test_parser_prec.cpp
    test/test_parser_postfix.cpp
    test/test_parser_custom.cpp
    test/test_parser_flow.cpp
    test/test_parser_fold.cpp
)
target_link_libraries(test_parser PRIVATE stope)

add_test(NAME parser COMMAND test_parser)
# 死循环兜底：parseAll 无法在进程内熔断 parser 的递归/循环，
# 由 ctest 的超时把"挂死"变成"失败"（全前缀截断 B-01 是最有效的防回归手段）。
set_tests_properties(parser PROPERTIES TIMEOUT 120)

# compiler 测试：parser 产出 AST → Program 的指令流。自成二进制，
# 与 test_parser 一样用 O_DOWN 运行。
add_executable(test_compiler test/test_compiler.cpp)
target_link_libraries(test_compiler PRIVATE stope)

add_test(NAME compiler COMMAND test_compiler)

# STML 测试：与 Stope 主语言是两套独立的 Lexer / Parser，只有 Result 与断言框架共用。
# 自成二进制：混进 test_parser 会让两边的失败信息互相干扰。
add_executable(test_stml
    test/test_stml.cpp
    test/test_stml_lexer.cpp
    test/test_stml_parser.cpp)
target_link_libraries(test_stml PRIVATE stope)

add_test(NAME stml COMMAND test_stml)
# 死循环兜底：stml_lexer 历史上就有 skipWs 缺 else break 这类不消费字符的坑。
set_tests_properties(stml PROPERTIES TIMEOUT 120)

# ast_visitor 测试：从 Compiler 抽出来的遍历骨架能不能独立当 walker 用。
# 与 compiler 分开二进制：两者虽然都跑 AST，但这组断言锁的是「默认遍历顺序」，
# 跟指令流没关系，混在一起只会让失败信息互相干扰。
add_executable(test_ast_visitor test/test_ast_visitor.cpp)
target_link_libraries(test_ast_visitor PRIVATE stope)

add_test(NAME ast_visitor COMMAND test_ast_visitor)

# vm 测试：编译 + 在 BasicVM 上执行 + 比对返回值。
# BasicVM 不是标准的一部分（只是参考实现），但这组断言锁的是「编译器产物能被
# 正确执行」—— 2026-10-22 删掉 ReplaceTopValues / GetValueTop 后，栈上不再有
# Identifier，这个转换靠的就是这套端到端用例来兜底。
add_executable(test_vm test/test_vm.cpp)
target_link_libraries(test_vm PRIVATE stope)

add_test(NAME vm COMMAND test_vm)

# 深嵌套探测：test_parser_depth <kind> <depth>
# 阈值是默认 8 MB 栈下的实测值（g++ 15.2 / MinGW-w64），换编译器或链接选项
# （-Wl,--stack）会变。崩溃深度由 run_depth.cmake 包装：被信号杀死时 ctest 报
# SegFault（WILL_FAIL 不反转"崩溃"判定），所以用 EXPECT=crash 显式登记。
add_executable(test_parser_depth test/test_parser_depth.cpp)
target_link_libraries(test_parser_depth PRIVATE stope)

set(STOPE_DEPTH_CASES
    paren 11000 ok      paren 12000 crash
    block 4000 ok       block 5000 crash
    unary 9000 ok       unary 10000 crash
    at    3000 ok       at    5000 crash)
while(STOPE_DEPTH_CASES)
  list(POP_FRONT STOPE_DEPTH_CASES kind depth expect)
  add_test(NAME parser-depth-${kind}-${depth}
           COMMAND ${CMAKE_COMMAND}
                   -DEXE=$<TARGET_FILE:test_parser_depth>
                   -DKIND=${kind} -DDEPTH=${depth} -DEXPECT=${expect}
                   -P ${CMAKE_CURRENT_SOURCE_DIR}/test/run_depth.cmake)
endwhile()
