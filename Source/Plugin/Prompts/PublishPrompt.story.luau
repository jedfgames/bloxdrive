--[[

PublishPrompt.story

Previews the Publish prompt as shown when the Publish toolbar button
is clicked on a new (unmarked) instance.

--]]

local Fusion = require("@packages/Fusion")

local PromptInput = require("../Components/PromptInput")

return {
    fusion = Fusion,
    story = function(props)
        local scope = props.scope

        scope:New("Frame")({
            Parent = props.target,
            Size = UDim2.fromOffset(300, 80),
            Position = UDim2.fromScale(0.5, 0.5),
            AnchorPoint = Vector2.new(0.5, 0.5),
            BackgroundTransparency = 1,

            [Fusion.Children] = PromptInput(scope, {
                DefaultValue = "MyPackage",
                PlaceholderText = "Enter package name...",
                OnSubmit = function(text: string)
                    print(`[Publish] Submitted "{text}"`)
                end,
            }),
        })
    end,
}
