local _ = require("gettext")

-- The one-line plugin-manager description, translated per UI language. It is
-- deliberately NOT run through gettext: _meta.lua is read by the plugin
-- manager before this plugin's own translations (locale/*.po) are ever
-- loaded, and our custom text isn't in KOReader's own gettext catalogs, so a
-- _() call here would just show English everywhere. Picking from this table
-- by the interface language's base code gives a real translation instead.
local DESCRIPTIONS = {
    en = "Reading statistics popups, achievements and reading goals built on KOReader's statistics database.",
    hu = "Olvasási statisztika-popupok, teljesítmények és olvasási célok a KOReader statisztikai adatbázisára építve.",
    de = "Lesestatistik-Popups, Erfolge und Leseziele auf Basis der Statistikdatenbank von KOReader.",
    pt = "Janelas de estatísticas de leitura, conquistas e metas de leitura com base na base de dados de estatísticas do KOReader.",
    zh = "基于 KOReader 统计数据库的阅读统计弹窗、成就与阅读目标。",
}

local function pickDescription()
    local lang = "en"
    if G_reader_settings and G_reader_settings.readSetting then
        lang = G_reader_settings:readSetting("language") or "en"
    end
    local base = tostring(lang):match("^([a-z][a-z])") or "en"
    return DESCRIPTIONS[base] or DESCRIPTIONS.en
end

return {
    -- KEEP `name`: some KOReader releases load a DISABLED plugin's identity
    -- from _meta.lua rather than main.lua, and key the plugin-manager
    -- enable/disable toggle off whatever name they find there. Without it,
    -- re-enabling this plugin after disabling it could get stuck (see
    -- bookshelf.koplugin's _meta.lua for the full writeup of this issue).
    name = "readinginsights",
    fullname = _("Reading insights"),
    -- Shown in KOReader's plugin manager (see DESCRIPTIONS above).
    description = pickDescription(),
    -- Bumped by the in-app updater (updater.lua) as new versions are
    -- installed. Keep in sync with the GitHub release tag (without the
    -- leading "v") each time a new release is cut.
    version = "5.1.6",
}
