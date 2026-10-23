var Opcode = {}
Opcode[Opcode["Assign"] = 0] = "Assign"
Opcode[Opcode["PushNull"] = 1] = "PushNull"
Opcode[Opcode["PushFalse"] = 2] = "PushFalse"
Opcode[Opcode["PushTrue"] = 3] = "PushTrue"
Opcode[Opcode["PushInt"] = 4] = "PushInt"
Opcode[Opcode["PushFloat"] = 5] = "PushFloat"
Opcode[Opcode["PushString"] = 6] = "PushString"
Opcode[Opcode["PushBinArr"] = 7] = "PushBinArr"
Opcode[Opcode["PushValue"] = 8] = "PushValue"
Opcode[Opcode["PushId"] = 9] = "PushId"

Opcode[Opcode["Call"] = 10] = "Call"
Opcode[Opcode["At"] = 11] = "At"
Opcode[Opcode["Pop"] = 12] = "Pop"
Opcode[Opcode["Minus"] = 13] = "Minus"
Opcode[Opcode["Not"] = 14] = "Not"
Opcode[Opcode["Pow"] = 15] = "Pow"
Opcode[Opcode["Mul"] = 16] = "Mul"
Opcode[Opcode["Div"] = 17] = "Div"
Opcode[Opcode["IDiv"] = 18] = "IDiv"
Opcode[Opcode["Mod"] = 19] = "Mod"

Opcode[Opcode["Add"] = 20] = "Add"
Opcode[Opcode["Sub"] = 21] = "Sub"
Opcode[Opcode["EQ"] = 22] = "EQ"
Opcode[Opcode["NE"] = 23] = "NE"
Opcode[Opcode["LT"] = 24] = "LT"
Opcode[Opcode["LE"] = 25] = "LE"
Opcode[Opcode["GT"] = 26] = "GT"
Opcode[Opcode["GE"] = 27] = "GE"
Opcode[Opcode["If"] = 28] = "If"
Opcode[Opcode["GoTo"] = 29] = "GoTo"

Opcode[Opcode["GetArg"] = 30] = "GetArg"
Opcode[Opcode["ArgNum"] = 31] = "ArgNum"
Opcode[Opcode["Return"] = 32] = "Return"

Object.freeze(Opcode)

export { Opcode }