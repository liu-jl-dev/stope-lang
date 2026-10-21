# 深嵌套探测的 ctest 包装器（测试计划 §5.8 B-03…B-06）。
#
# 背景：这些用例会真的栈溢出。被信号杀死时 ctest 报 Exception/SegFault，
# WILL_FAIL 只反转"退出码"判定、不反转"崩溃"判定，所以要用本脚本把
# "崩"翻译成符合预期的结果。
#
# 用法：
#   cmake -DEXE=<test_parser_depth 路径> -DKIND=paren -DDEPTH=12000 \
#         -DEXPECT=crash -P run_depth.cmake
#   EXPECT ∈ crash（该深度应当崩）| ok（该深度应当正常结束）

if(NOT DEFINED EXE OR NOT DEFINED KIND OR NOT DEFINED DEPTH OR NOT DEFINED EXPECT)
  message(FATAL_ERROR "need EXE, KIND, DEPTH, EXPECT")
endif()

execute_process(
  COMMAND "${EXE}" "${KIND}" "${DEPTH}"
  RESULT_VARIABLE rc
  OUTPUT_VARIABLE out
  ERROR_VARIABLE err
)
string(STRIP "${out}" out)
message(STATUS "depth ${KIND} ${DEPTH}: rc=[${rc}] out=[${out}]")

# MinGW 上被信号杀死的进程，execute_process 的 RESULT_VARIABLE 是
# "Stack overflow" 这样的字符串而不是负数；能解析成整数的才算正常退出码。
if(rc MATCHES "^-?[0-9]+$")
  set(actual "exit ${rc}")
else()
  set(actual crash)
endif()

if(actual STREQUAL EXPECT OR (EXPECT STREQUAL ok AND rc EQUAL 0))
  message(STATUS "depth ${KIND} ${DEPTH}: ${actual} 符合预期")
else()
  message(FATAL_ERROR "depth ${KIND} ${DEPTH}: 期望 ${EXPECT}，实际 ${actual}")
endif()
