--[[

SetKeyPrompt.story

Previews the Set Key dialog with info section, key status, input,
validation, and remove controls.

--]]

local Fusion = require("@packages/Fusion")

local SetKeyPrompt = require("../Components/SetKeyPrompt")

return {
    fusion = Fusion,
    story = function(props)
        local scope = props.scope

        local ui = SetKeyPrompt(scope, {
            CurrentKey = nil,
            OnSave = function(key: string)
                print(`[Set Key] Saved key ({#key} characters)`)
            end,
            OnRemove = function()
                print("[Set Key] Key removed")
            end,
        })

        ui.Size = UDim2.fromOffset(320, 300)
        ui.Position = UDim2.fromScale(0.5, 0.5)
        ui.AnchorPoint = Vector2.new(0.5, 0.5)
        ui.Parent = props.target
    end,
}
