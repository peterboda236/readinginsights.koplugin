--[[
Reading Insights - shared plugin bootstrap helper.

The plugin's own files live in <koreader>/plugins/readinginsights.koplugin/,
which is deliberately NOT on package.path (see main.lua's header) - so
require() can't find sibling files, and every file that needs to load
another plugin file, or resolve a path relative to itself, previously
carried its own private copy of the same debug.getinfo(...) directory
snippet plus a loadfile() wrapper.

This module centralises both:

  PluginUtil.dir            the plugin's own directory (with trailing "/")
  PluginUtil.load(name,...) loadfile() that file from the plugin directory
                            and call the resulting chunk with `...`

Every plugin file lives in the same directory, so the directory computed
here (once) is the same one each of them used to recompute for itself.
main.lua bootstraps this module with a tiny inline loader and then passes
it to the other files, so this single copy replaces the four identical
pluginDir()/loadLocal() definitions that used to live in main.lua,
locale.lua, colors.lua and fonts.lua.
]]--

local M = {}

local src = debug.getinfo(1, "S").source
M.dir = src:match("^@(.*/)") or "./"

-- Loads <name> from this plugin's directory and calls the resulting chunk
-- with `...` as its arguments (e.g. the shared Locale module).
function M.load(name, ...)
    local path = M.dir .. name
    local chunk, err = loadfile(path)
    if not chunk then
        error(("Reading Insights: failed to load %s: %s"):format(name, tostring(err)))
    end
    return chunk(...)
end

return M
