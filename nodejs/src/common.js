var Result = {}
Result[Result["Success"] = 0] = "Success"
Result[Result["Error"] = 1] = "Error"
Result[Result["UnknownError"] = 2] = "UnknownError"
Result[Result["DuplicateWithBuiltinOpcode"] = 3] = "DuplicateWithBuiltinOpcode"

Object.freeze(Result)

export {
  Result,
}