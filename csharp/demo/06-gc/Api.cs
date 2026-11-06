using Stope;

namespace Stope.Demo;

// ==================== Api：三个开口薄转发到 ObjectManager ====================

internal sealed class DemoApi : Api
{
    private readonly ObjectManager _objMgr;

    public DemoApi(ObjectManager objMgr) => _objMgr = objMgr;

    public override object? HandleAt(State s, Handle handle, object? key) =>
        _objMgr.At(s, handle, key);

    public override void HandleAssign(State s, Handle handle, object? value) =>
        _objMgr.Assign(s, handle, value);

    public override object? HandleCall(State s, Handle handle, object?[] args) =>
        _objMgr.CallMember(s, handle, args);
}
