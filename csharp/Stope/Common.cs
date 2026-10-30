namespace Stope;

/// <summary>
/// 编译器 / 词法器 / STML 共用的返回码 —— 与 <c>cpp/include/stope/common.hpp</c> 的
/// <c>Result</c> 同序同值。<c>Success == 0</c>，所以别写 <c>if (rc != 0)</c> 之外的猜测：
/// 只有 <c>Success</c> 表示成功。
/// </summary>
public enum Result
{
    Success = 0,
    Error = 1,
    UnknownError = 2,
    DuplicateWithBuiltinOpcode = 3,
}
