--[[
Reading Insights - small calendar-date helpers.

Pure date arithmetic, nothing language-related (that lives in locale.lua).
Loaded once by main.lua and handed to the views that need it, replacing the
four private "days in this month" copies they used to carry.
]]--

local M = {}

-- Number of days (28-31) in month `m` (1-12) of year `y`.
-- Day 0 of the next month is the last day of this one; os.time normalises
-- month 13 into January of the next year. Noon is used so a daylight-saving
-- jump around midnight can never push the result into the previous day.
function M.daysInMonth(y, m)
    local t = os.time{ year = y, month = m + 1, day = 0, hour = 12 }
    if not t then return 31 end -- out-of-range year; os.date(nil) would mean "now"
    return os.date("*t", t).day
end

return M
