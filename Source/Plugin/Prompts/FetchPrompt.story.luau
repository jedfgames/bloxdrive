--[[

FetchPrompt.story

Previews the Fetch prompt as shown when the Fetch toolbar button is
clicked without a package marker on the selected instance.

--]]

const Fusion = require("@packages/Fusion")

const PromptInput = require("../Components/PromptInput")

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
                PlaceholderText = "Enter package ID...",
                OnSubmit = function(text: string)
                    print(`[Fetch] Submitted "{text}"`)
                end,
            }),
        })
    end,
}
