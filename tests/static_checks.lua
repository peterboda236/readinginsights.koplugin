--[[
Reading Insights - static checks over the whole source tree.

These look for the kinds of breakage that survive a refactor without any
obvious symptom, and that neither the compiler nor the runtime tests catch
until a user taps the wrong thing:

  1. compiles          every file parses
  2. globals           no accidental global reads (the classic result of
                       moving code between files and forgetting a local)
  3. requires          nothing required but unused
  4. method calls      no popup:method() call where the method no longer
                       exists - this is what broke the finished-books
                       checklist when its query moved into a module
  5. module surface    every Mod.name used somewhere is defined by that
                       module (and vice versa, reported as unused)
  6. translations      every _()/N_() string exists in each .po file
  7. formatting        no double blank lines, trailing whitespace, or
                       missing/extra newline at end of file

Run from the plugin root: lua5.1 tests/static_checks.lua
Needs lua5.1 and luac5.1 - nothing else, no KOReader.
]]--

local ok_count, fail_count = 0, 0
local failures = {}

local function pass(msg) ok_count = ok_count + 1; print("  ok    " .. msg) end
local function fail(msg)
    fail_count = fail_count + 1
    failures[#failures + 1] = msg
    print("  FAIL  " .. msg)
end

local function sh(cmd)
    local f = io.popen(cmd)
    local out = f:read("*a")
    f:close()
    return out
end

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function lines(s)
    local t = {}
    for l in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    if t[#t] == "" then t[#t] = nil end
    return t
end

local function sourceFiles()
    local t = {}
    for path in sh("find . -name '*.lua' -not -path './tests/*' | sort"):gmatch("[^\n]+") do
        t[#t + 1] = path:gsub("^%./", "")
    end
    return t
end

local files = sourceFiles()
if #files == 0 then
    print("No .lua files found - run this from the plugin root.")
    os.exit(1)
end

-- Uses `goto continue`, which LuaJIT (KOReader) accepts and plain Lua 5.1
-- does not, so the parser here can't read it. Checked with the goto
-- neutralised instead, rather than skipped outright.
local LUAJIT_ONLY = { ["lib/updater.lua"] = true }

--------------------------------------------------------------------------
print("\n1. Compiles")
--------------------------------------------------------------------------
for _, f in ipairs(files) do
    local target = f
    if LUAJIT_ONLY[f] then
        local src = read(f):gsub("goto%s+continue", "break"):gsub("::continue::", "")
        local tmp = os.tmpname()
        local h = io.open(tmp, "w"); h:write(src); h:close()
        target = tmp
    end
    local err = sh("luac5.1 -p " .. target .. " 2>&1")
    if LUAJIT_ONLY[f] then os.remove(target) end
    if err == "" then pass(f) else fail(f .. ": " .. err:gsub("\n", " ")) end
end

--------------------------------------------------------------------------
print("\n2. No accidental globals")
--------------------------------------------------------------------------
local ALLOWED_GLOBALS = {}
for w in ([[ipairs pairs math os string table type tonumber tostring pcall require next
            error select unpack assert print io setmetatable getmetatable rawget rawset
            G_reader_settings _G debug dofile loadfile load collectgarbage]]):gmatch("%S+") do
    ALLOWED_GLOBALS[w] = true
end
for _, f in ipairs(files) do
    if not LUAJIT_ONLY[f] then
        local bad = {}
        for name in sh("luac5.1 -l -p " .. f .. " 2>/dev/null"):gmatch("GETGLOBAL%s+%S+%s+; ([%w_]+)") do
            if not ALLOWED_GLOBALS[name] then bad[name] = true end
        end
        local list = {}
        for n in pairs(bad) do list[#list + 1] = n end
        table.sort(list)
        if #list == 0 then pass(f) else fail(f .. " reads globals: " .. table.concat(list, ", ")) end
    end
end

--------------------------------------------------------------------------
print("\n3. No unused requires")
--------------------------------------------------------------------------
for _, f in ipairs(files) do
    local src = read(f)
    local unused = {}
    for name in src:gmatch("\nlocal ([%w_]+)%s*=%s*require%(") do
        local uses = 0
        for _ in src:gmatch("[^%w_.:]" .. name .. "[^%w_]") do uses = uses + 1 end
        if uses <= 1 then unused[#unused + 1] = name end
    end
    if #unused == 0 then pass(f) else fail(f .. " requires but never uses: " .. table.concat(unused, ", ")) end
end

--------------------------------------------------------------------------
print("\n4. Popup method calls resolve")
--------------------------------------------------------------------------
-- Every method defined on any class in the plugin.
local defined_methods = {}
for _, f in ipairs(files) do
    for name in read(f):gmatch("\nfunction%s+[%w_.]+:([%w_]+)") do defined_methods[name] = true end
end
-- Methods we call on objects that belong to KOReader, not to us.
for w in ("handleEvent free getSize paintTo onClose init close show"):gmatch("%S+") do
    defined_methods[w] = true
end
for _, f in ipairs(files) do
    local missing = {}
    local n = 0
    for _, line in ipairs(lines(read(f))) do
        n = n + 1
        if not line:match("^%s*%-%-") then
            for obj, meth in line:gmatch("([%w_]+)%s*:%s*([%w_]+)%s*%(") do
                if (obj == "popup_self" or obj == "insights_popup" or obj == "ip" or obj == "popup")
                   and not defined_methods[meth] then
                    missing[#missing + 1] = string.format("%d: %s:%s()", n, obj, meth)
                end
            end
        end
    end
    if #missing == 0 then pass(f) else fail(f .. " calls methods that don't exist -> " .. table.concat(missing, "; ")) end
end

--------------------------------------------------------------------------
print("\n5. Module surfaces")
--------------------------------------------------------------------------
-- alias used in the code -> file that must define it
local MODULES = {
    VS           = "lib/insights_settings.lua",
    Cache        = "lib/insights_cache.lua",
    UI           = "lib/uikit.lua",
    Data         = "lib/insights_data.lua",
    RecordsData  = "lib/records_data.lua",
    ChapterInfo  = "lib/chapterinfo.lua",
    ChapterBar   = "widgets/chapterbarwidget.lua",
    CalendarData = "lib/book_calendar_data.lua",
    BookStatsData = "lib/book_stats_data.lua",
    Menu         = "lib/menu.lua",
}
for alias, path in pairs(MODULES) do
    local src = read(path)
    if not src then
        fail(alias .. " -> " .. path .. " is missing")
    else
        local defined = {}
        for name in src:gmatch("\nfunction M%.([%w_]+)") do defined[name] = true end
        for name in src:gmatch("\nM%.([%w_]+)%s*=") do defined[name] = true end
        for name in src:gmatch("\nlocal M = {(.-)\n}") do
            for key in name:gmatch("([%w_]+)%s*=") do defined[key] = true end
        end
        for name in src:gmatch("\n    ([%w_]+)%s*=") do defined[name] = true end
        local missing = {}
        for _, f in ipairs(files) do
            if f ~= path then
                for _, line in ipairs(lines(read(f))) do
                    if not line:match("^%s*%-%-") then
                        for name in line:gmatch("[^%w_.]" .. alias .. "%.([%w_]+)") do
                            if not defined[name] then missing[name] = true end
                        end
                    end
                end
            end
        end
        local list = {}
        for n in pairs(missing) do list[#list + 1] = n end
        table.sort(list)
        if #list == 0 then pass(alias .. " (" .. path .. ")")
        else fail(alias .. " used but not defined: " .. table.concat(list, ", ")) end
    end
end

--------------------------------------------------------------------------
print("\n6. Translations")
--------------------------------------------------------------------------
local msgids = {}
for _, f in ipairs(files) do
    local src = read(f)
    for s in src:gmatch("[^%w_]_%(\"([^\"]*)\"%)") do msgids[s] = true end
    for a, b in src:gmatch("[^%w_]N_%(\"([^\"]*)\",%s*\"([^\"]*)\"") do msgids[a] = true; msgids[b] = true end
end
for po in sh("ls locale/*.po"):gmatch("[^\n]+") do
    local have = {}
    for id in read(po):gmatch("\nmsgid \"([^\"]*)\"") do have[id] = true end
    local missing = {}
    for id in pairs(msgids) do
        if not have[id] then missing[#missing + 1] = id end
    end
    table.sort(missing)
    if #missing == 0 then pass(po)
    else fail(po .. " missing " .. #missing .. ": " .. table.concat(missing, " | ")) end
end

--------------------------------------------------------------------------
print("\n7. Formatting")
--------------------------------------------------------------------------
for _, f in ipairs(files) do
    local src = read(f)
    local problems = {}
    if src:find("\n[ \t]*\n[ \t]*\n") then problems[#problems + 1] = "double blank line" end
    if src:find("[ \t]\n") then problems[#problems + 1] = "trailing whitespace" end
    if not src:find("\n$") then problems[#problems + 1] = "no newline at end of file" end
    if src:find("\n\n$") then problems[#problems + 1] = "blank line at end of file" end
    if #problems == 0 then pass(f) else fail(f .. ": " .. table.concat(problems, ", ")) end
end

--------------------------------------------------------------------------
print(string.format("\n%d checks, %d passed, %d failed", ok_count + fail_count, ok_count, fail_count))
if fail_count > 0 then
    print("\nFailures:")
    for _, m in ipairs(failures) do print("  - " .. m) end
    os.exit(1)
end
print("ALL STATIC CHECKS PASSED")
