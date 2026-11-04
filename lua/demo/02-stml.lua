-- demo 02-stml.lua：STML —— 解析一份标记文档，把里面的代码段原样切出来。
--
-- STML 是「两半」：树的形状（标签、属性、嵌套、结束标签是否配对）由 StmlParser 管；
-- 「某个元素的内容怎么切」由宿主的回调决定 —— 是子元素、纯文本，还是一段代码。
--
-- 只解析，不编译也不执行：拿到 text 之后干什么完全是宿主的事。
--
-- 运行：lua demo/02-stml.lua

-- 定位本文件，把 lua/ 挂进 package.path（任何 cwd 都能跑）
local src = debug.getinfo(1, "S").source
if string.sub(src, 1, 1) == "@" then src = string.sub(src, 2) end
src = src:gsub("\\", "/")
local demo_dir = src:match("^(.*)/[^/]+$") or "."
local root = demo_dir:match("^(.*)/demo$") or demo_dir
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local stope = require("stope")

local DOC = [[
<stml package="MyPkg">

<config>
  windowTitle "demo";
  windowSize 1280, 720
</config>
<func name="myFunc" stope>
  let a = 1;
  return a + argc;
</func>
<class name="Person">
  <property name="name" />
  <property name="age" />
  <method name="greet" />
</class>

</stml>
]]

--- 宿主回调：读完开始标签、还没进内容时调用一次，返回值决定这段内容怎么扫。
local function content_kind(tag, attrs)
    if tag == "config" then
        return stope.StmlState.Nevext -- 一段 Nevext 代码，整段原样保留
    elseif attrs["stope"] ~= nil then
        return stope.StmlState.Stope -- 一段 Stope 代码
    end
    return stope.StmlState.Xml -- 默认：内容是子元素列表
end

--- 按名字找子元素 —— 别写死下标，空行和注释都会让它变。
local function child(ele, tag)
    for _, c in ipairs(ele.children) do
        if c.tag == tag then return c end
    end
    return nil
end

local function main()
    local lexer = stope.StmlLexer.new(DOC)
    local parser = stope.StmlParser.new(lexer)
    local root = stope.StmlElement()
    if parser:parse(root, content_kind) ~= stope.Result.Success then
        local errs = {}
        for _, e in ipairs(lexer.errors) do errs[#errs + 1] = e end
        for _, e in ipairs(parser.errors) do errs[#errs + 1] = e end
        error(table.concat(errs, "\n"))
    end

    print("[1] 根元素 <" .. root.tag .. ">，属性 package=\"" .. root.attrs["package"] .. "\"")
    print("[2] 它的直接子元素：")
    for _, c in ipairs(root.children) do
        print("  " .. c.tag)
    end

    print("[3] <class> 的子元素：")
    for _, c in ipairs(child(root, "class").children) do
        print("  " .. c.tag .. (c.self_closing and "(自闭合)" or ""))
    end

    -- 代码段是原样的一整段文本：换行是真的换行、缩进保留（只有尾部空白被词法裁掉）。
    -- 拿到它交给 stope.Lexer 就能编译执行（见 01-quick-start.lua）—— STML 不管代码写得对不对。
    print("[4] <func> 里的 Stope 代码段：")
    io.write(child(root, "func").text .. "\n")
end

main()
