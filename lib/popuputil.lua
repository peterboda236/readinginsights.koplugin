--[[
Reading Insights - shared popup boilerplate.

Several of this plugin's simple "show some info, tap/swipe/key to dismiss"
modal popups (the About box, the records popup, the weekly-trend popup)
carried byte-for-byte identical dismiss handlers:

    function X:onTap()           UIManager:close(self) return true end
    function X:onSwipe()         UIManager:close(self) return true end
    function X:onAnyKeyPressed() UIManager:close(self) return true end

plus a matching pair of redraw handlers that only differed in which
sub-widget's dimen they marked dirty:

    function X:onShow()        UIManager:setDirty(self, ...dimen...) return true end
    function X:onCloseWidget() UIManager:setDirty(nil,  ...dimen...) end

PopupUtil.makeDismissable(class, get_dimen) installs all five on `class`.
`get_dimen(self)` returns the screen region to refresh (e.g.
self.box_content.dimen), so each popup keeps its own redraw region while
sharing the (previously duplicated) handler bodies.

This only fits popups whose *only* interaction is "any gesture dismisses";
popups with their own tap/swipe navigation (the chapter bar, the calendar,
the heatmap pager) keep their bespoke handlers.
]]--

local UIManager = require("ui/uimanager")

local M = {}

function M.makeDismissable(class, get_dimen)
    function class:onTap()           UIManager:close(self) return true end
    function class:onSwipe()         UIManager:close(self) return true end
    function class:onAnyKeyPressed() UIManager:close(self) return true end

    function class:onShow()
        UIManager:setDirty(self, function()
            return "ui", get_dimen(self)
        end)
        return true
    end

    function class:onCloseWidget()
        UIManager:setDirty(nil, function()
            return "ui", get_dimen(self)
        end)
    end
end

return M
