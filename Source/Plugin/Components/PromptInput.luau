--[[

PromptInput

A text input prompt with a submit button. Submits on Enter key or
button click. Calls the OnSubmit callback with the text value.

--]]

local Fusion = require("@packages/Fusion")

local Children = Fusion.Children
local OnChange = Fusion.OnChange
local OnEvent = Fusion.OnEvent

type UsedAs<T> = Fusion.UsedAs<T>

return function(
    scope: Fusion.Scope,
    props: {
        DefaultValue: UsedAs<string>?,
        OnSubmit: ((text: string) -> ())?,
        PlaceholderText: UsedAs<string>?,
    }
): Fusion.Child
    local text = scope:Value(Fusion.peek(props.DefaultValue) or "")

    local function submit()
        local value = Fusion.peek(text)
        if value ~= "" and props.OnSubmit then
            props.OnSubmit(value)
        end
    end

    return scope:New("Frame")({
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.fromRGB(46, 46, 46),
        BorderSizePixel = 0,

        [Children] = {
            scope:New("TextBox")({
                Name = "Input",
                Size = UDim2.new(1, -20, 0, 30),
                Position = UDim2.fromOffset(10, 10),
                BackgroundColor3 = Color3.fromRGB(30, 30, 30),
                TextColor3 = Color3.fromRGB(255, 255, 255),
                FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json"),
                TextSize = 14,
                Text = props.DefaultValue or "",
                PlaceholderText = props.PlaceholderText or "Enter value...",
                PlaceholderColor3 = Color3.fromRGB(150, 150, 150),
                ClearTextOnFocus = false,

                [OnChange("Text")] = function(newText: string)
                    text:set(newText)
                end,

                [OnEvent("FocusLost")] = function(enterPressed: boolean)
                    if enterPressed then
                        submit()
                    end
                end,
            }),

            scope:New("TextButton")({
                Name = "Submit",
                Size = UDim2.new(0, 80, 0, 25),
                Position = UDim2.new(0.5, -40, 1, -35),
                BackgroundColor3 = Color3.fromRGB(0, 120, 215),
                TextColor3 = Color3.fromRGB(255, 255, 255),
                FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
                TextSize = 14,
                Text = "Submit",

                [OnEvent("MouseButton1Click")] = function()
                    submit()
                end,
            }),
        },
    })
end
