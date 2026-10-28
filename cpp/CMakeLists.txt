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

# STML：解析一份内嵌标记文档，把里面的三种代码段原样切出来。
add_executable(demo02 demo/02-stml.cpp)
target_include_directories(demo02 PUBLIC include)
target_link_libraries(demo02 PRIVATE stope)

# 自定义指令：只编译 + 反汇编（DumpProgram + CustomOpcodeConfig），不接执行器。
add_executable(demo03 demo/03-custom-opcode.cpp)
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

# ---------------------------------------------------------------------------
# golden 数据生成（给 GDScript 侧测试用，**不属于 ctest**）
#
# 探针源码在 tools/（C++ 侧代码不放进 GDScript 工程目录）。它们必须链接 stope
# 库 —— 期望值只能由权威实现产出，不能让被测实现自证（那样测试永远绿，等于没测）。
# 挂在 CMake 里的目的只是让「改完 C++ 顺手刷新期望值」变成一条命令：
#
#     cmake --build build --target gen-golden
#
# 好处：不用记 4 条 g++ 命令和它们的 -I / -std 参数；探针链接的是 stope 静态
# 库，改了 C++ 接口会**编译期报错**，不会静默沿用旧数据。
#
# 数据落点仍是 gdscript/test/data/ —— Godot 的 res:// 只认工程目录内的文件，
# 挪到仓库根就读不到了。探针源码与产出数据分居两边，这是刻意的。
# ---------------------------------------------------------------------------
get_filename_component(STOPE_GD_DATA "${CMAKE_CURRENT_SOURCE_DIR}/../gdscript/test/data" ABSOLUTE)
set(STOPE_GEN_DRIVER "${CMAKE_CURRENT_SOURCE_DIR}/cmake/run_gen.cmake")

foreach(STOPE_GEN_PROBE golden golden_lex golden_binarr golden_stml golden_disasm)
  add_executable(gen_${STOPE_GEN_PROBE} EXCLUDE_FROM_ALL "tools/${STOPE_GEN_PROBE}.cpp")
  # 探针里写的是 `#include "compiler.hpp"` 这类裸名，所以除了 test/ 还要补 include/stope。
  target_include_directories(gen_${STOPE_GEN_PROBE} PRIVATE test include/stope)
  target_link_libraries(gen_${STOPE_GEN_PROBE} PRIVATE stope)
endforeach()

# 一次性重生成四份数据。custom target 每次都算"过期"，这正是想要的：
# 它只描述动作，不参与增量判断。
add_custom_target(gen-golden
  COMMAND ${CMAKE_COMMAND} -DEXE=$<TARGET_FILE:gen_golden>
          -DOUT=${STOPE_GD_DATA}/golden.txt -P ${STOPE_GEN_DRIVER}
  COMMAND ${CMAKE_COMMAND} -DEXE=$<TARGET_FILE:gen_golden_lex>
          -DOUT=${STOPE_GD_DATA}/golden_lex.txt -P ${STOPE_GEN_DRIVER}
  COMMAND ${CMAKE_COMMAND} -DEXE=$<TARGET_FILE:gen_golden_binarr>
          -DOUT=${STOPE_GD_DATA}/golden_binarr.txt -P ${STOPE_GEN_DRIVER}
  COMMAND ${CMAKE_COMMAND} -DEXE=$<TARGET_FILE:gen_golden_stml>
          -DOUT=${STOPE_GD_DATA}/golden_stml.txt
          -DARGS=${STOPE_GD_DATA}/stml_cases.txt -P ${STOPE_GEN_DRIVER}
  COMMAND ${CMAKE_COMMAND} -DEXE=$<TARGET_FILE:gen_golden_disasm>
          -DOUT=${STOPE_GD_DATA}/golden_disasm.txt -P ${STOPE_GEN_DRIVER}
  DEPENDS gen_golden gen_golden_lex gen_golden_binarr gen_golden_stml gen_golden_disasm
  # 注释用英文：MinGW Makefiles 下把中文写进 COMMENT 会按 GBK 解释成乱码。
  COMMENT "Regenerating GDScript golden data (5 files)"
  VERBATIM)
