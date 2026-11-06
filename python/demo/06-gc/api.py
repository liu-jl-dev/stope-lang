# api.py：三个开口薄转发到 ObjectManager（对应 C++ 的 API.*）。

from stope import Api


class DemoApi(Api):
    def __init__(self, obj_mgr):
        super().__init__()
        self.obj_mgr = obj_mgr

    def handle_at(self, s, handle, key):
        return self.obj_mgr.at(s, handle, key)

    def handle_assign(self, s, handle, value):
        self.obj_mgr.assign(s, handle, value)

    def handle_call(self, s, handle, args):
        return self.obj_mgr.call_member(s, handle, args)
