//! 编译产物 `Program`：指令流 + 常量池 + 变量表 —— 对齐 `python/stope/program.py`。
//!
//! 整数常量语义上是 int64（写进 `int_consts` 之前已经过 64 位回绕）。

/// 可直接编译 / 执行的空程序。
#[derive(Debug, Default, Clone)]
pub struct Program {
    /// 指令与操作数混排（int16 范围内；`-1` 是未回填的占位）
    pub opcodes: Vec<i32>,
    /// 变量数量
    pub variable_num: i32,
    /// 导出变量名 → 槽位（BTreeMap：dump 与 golden 一致按名字字典序）
    pub exports: std::collections::BTreeMap<String, i32>,
    pub int_consts: Vec<i64>,
    pub float_consts: Vec<f64>,
    pub string_consts: Vec<String>,
    pub binarr_consts: Vec<Vec<u8>>,
    /// return 语句最大返回值数量
    pub max_return_num: i32,
    pub required_stack_size: i32,
}

impl Program {
    pub fn new() -> Self {
        Program {
            opcodes: Vec::new(),
            variable_num: 0,
            exports: std::collections::BTreeMap::new(),
            int_consts: Vec::new(),
            float_consts: Vec::new(),
            string_consts: Vec::new(),
            binarr_consts: Vec::new(),
            max_return_num: 0,
            required_stack_size: 0,
        }
    }

    /// 清空成「刚构造」的状态（编译器在每次 compile 开头调用）。
    pub fn clear(&mut self) {
        self.opcodes.clear();
        self.int_consts.clear();
        self.float_consts.clear();
        self.string_consts.clear();
        self.binarr_consts.clear();
        self.exports.clear();
        self.variable_num = 0;
        self.max_return_num = 0;
        self.required_stack_size = 0;
    }
}
