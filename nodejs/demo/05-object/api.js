// api.js：三个开口薄转发到 ObjectManager（对应 C++ 的 API.*）。

import { BasicVM } from '../../src/index.js'

export class DemoApi extends BasicVM.Api {
  constructor(objMgr) {
    super()
    this.objMgr = objMgr
  }
  handleAt(s, handle, key) {
    return this.objMgr.at(s, handle, key)
  }
  handleAssign(s, handle, value) {
    this.objMgr.assign(s, handle, value)
  }
  handleCall(s, handle, args) {
    return this.objMgr.callMember(s, handle, args)
  }
}
