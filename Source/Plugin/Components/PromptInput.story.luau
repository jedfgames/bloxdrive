--[[

PromptInput Story

Previews the PromptInput component in UI Labs. Story files use
script-relative requires since they run live in Studio via Rojo
serve, not through the build pipeline.

--]]

local Fusion = require("@packages/Fusion")

local PromptInput = require(script.Parent.PromptInput)

return {
    fusion = Fusion,
    controls = {},
    story = function(props)
        local scope = props.scope

        scope:New("Frame")({
            Parent = props.target,
            Size = UDim2.fromOffset(300, 80),
            Position = UDim2.fromScale(0.5, 0.5),
            AnchorPoint = Vector2.new(0.5, 0.5),
            BackgroundTransparency = 1,

            [Fusion.Children] = PromptInput(scope, {
                DefaultValue = "HelloWorld",
                PlaceholderText = "Enter package name...",
                OnSubmit = function(text: string)
                    print(`Submitted "{text}"`)
                end,
            }),
        })
    end,
}
