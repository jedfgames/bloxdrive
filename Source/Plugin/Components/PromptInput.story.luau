--[[

PromptInput.story

Previews the PromptInput component in UI Labs.

--]]

const Fusion = require("@packages/Fusion")

const PromptInput = require("./PromptInput")

return {
    fusion = Fusion,
    story = function(props)
        const scope = props.scope

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
