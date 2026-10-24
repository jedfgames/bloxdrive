--[[

SetKeyPrompt.story

Previews the Set Key dialog with info section, key status, input,
validation, and remove controls.

--]]

const Fusion = require("@packages/Fusion")

const SetKeyPrompt = require("../Components/SetKeyPrompt")

return {
    fusion = Fusion,
    story = function(props)
        const scope = props.scope

        const ui = SetKeyPrompt(scope, {
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
