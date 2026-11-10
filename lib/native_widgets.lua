--[[
Reading Insights - the stock KOReader dialogs the plugin's popups open.

In the file manager, Simple UI (simpleui.koplugin) swaps ButtonDialog,
ConfirmBox, InfoMessage, SpinWidget and DoubleSpinWidget for its own
non-modal sheet, which UIManager stacks under our modal popups - it only
shows up once the popup is closed. It swaps the exact classes only, never a
subclass, so the popups open these subclasses instead.
]]--

return {
    ButtonDialog     = require("ui/widget/buttondialog"):extend{},
    ConfirmBox       = require("ui/widget/confirmbox"):extend{},
    DoubleSpinWidget = require("ui/widget/doublespinwidget"):extend{},
    InfoMessage      = require("ui/widget/infomessage"):extend{},
    SpinWidget       = require("ui/widget/spinwidget"):extend{},
}
