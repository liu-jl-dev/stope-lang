package tests

import "stope"

// golden 里所有用例都带着这两条自定义指令（与 cpp/tools/golden.cpp 的 g_cfg 一致）
var CFG = func() *stope.CustomOpcodeConfig {
	c := stope.NewCustomOpcodeConfig()
	c.AddCustomOpcode("myop", 100, 2)
	c.AddCustomOpcode("vop", 101, -1)
	return c
}()
