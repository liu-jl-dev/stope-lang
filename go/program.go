package stope

// 编译产物 Program：指令流 + 常量池 + 变量表。对应 cpp/include/stope/program.hpp。

// ExportEntry 一条导出：名字 → 槽位。保序（demo 按登记顺序打印；golden 比对按名字排序）。
type ExportEntry struct {
	Name  string
	Index int
}

// Program 可直接编译 / 执行的空程序（与 C++ 的默认构造一致）。
type Program struct {
	Opcodes           []int // 指令与操作数混排，int16 范围内
	VariableNum       int   // 变量数量
	Exports           []ExportEntry
	IntConsts         []int64
	FloatConsts       []float64
	StringConsts      []string
	BinarrConsts      [][]byte
	MaxReturnNum      int // return 语句最大返回值数量
	RequiredStackSize int
}

// NewProgram 构造空程序。
func NewProgram() *Program { return &Program{} }

// Clear 清空成「刚构造」的状态（编译器在每次 Compile 开头调用）。
func (p *Program) Clear() {
	p.Opcodes = p.Opcodes[:0]
	p.IntConsts = p.IntConsts[:0]
	p.FloatConsts = p.FloatConsts[:0]
	p.StringConsts = p.StringConsts[:0]
	p.BinarrConsts = p.BinarrConsts[:0]
	p.Exports = p.Exports[:0]
	p.VariableNum = 0
	p.MaxReturnNum = 0
	p.RequiredStackSize = 0
}

// SetExport 记录一条导出（同名覆盖值但保持首次出现的位置）。
func (p *Program) SetExport(name string, idx int) {
	for i := range p.Exports {
		if p.Exports[i].Name == name {
			p.Exports[i].Index = idx
			return
		}
	}
	p.Exports = append(p.Exports, ExportEntry{name, idx})
}

// ExportOf 按名字查槽位；不存在返回 (0, false)。
func (p *Program) ExportOf(name string) (int, bool) {
	for _, e := range p.Exports {
		if e.Name == name {
			return e.Index, true
		}
	}
	return 0, false
}
