# golden 数据生成驱动（由 `gen-golden` target 调用，不在 ctest 里）。
#
# 为什么用 -P 脚本而不是在 add_custom_target 里写 `exe > file`：
# 重定向是 shell 语法，CMake 的 COMMAND 不保证跨平台；execute_process 能直接
# 拿到退出码，失败时能把探针的 stderr 报出来。
#
# 用法：
#   cmake -DEXE=<探针可执行文件> -DOUT=<输出文件> [-DARGS=a;b] -P run_gen.cmake
#
# 行尾**故意不在这里处理**：探针在 Windows 上按文本模式输出 CRLF，Linux 上输出
# LF，而 .gitattributes 的 `* text=auto` 会把入库内容统一成 LF、检出时再按平台
# 转换。在这里强行改一遍反而会和 git 打架 —— 实测 `file(WRITE)` 在 Windows 上
# 会把 `\n` 重新转成 `\r\n`，等于白做。读侧（`test_util.gd` 的 `read_golden`）
# 本来就兜底剥 `\r`。

if(NOT DEFINED EXE OR NOT DEFINED OUT)
  message(FATAL_ERROR "run_gen.cmake 需要 -DEXE= 与 -DOUT=")
endif()

execute_process(
  COMMAND "${EXE}" ${ARGS}
  RESULT_VARIABLE rc
  OUTPUT_FILE "${OUT}"
  ERROR_VARIABLE err
)
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "探针执行失败（rc=${rc}）：${err}")
endif()

file(SIZE "${OUT}" size_bytes)
message(STATUS "gen: ${OUT}（${size_bytes} 字节）")
