--!nocheck

--[[

SetKeyPrompt

Dialog for managing the registry key. Shows an info section
explaining what the key is for, displays the current key status,
and provides controls to set, test, or remove the key.

--]]

local HttpService = game:GetService("HttpService")

local Fusion = require("@packages/Fusion")

local Children = Fusion.Children
local OnChange = Fusion.OnChange
local OnEvent = Fusion.OnEvent

local REGISTRY_URL = "https://rbx-package-registry.batchprogrammer314.workers.dev"

type UsedAs<T> = Fusion.UsedAs<T>

type SetKeyPromptProps = {
    CurrentKey: string?,
    OnSave: ((key: string) -> ())?,
    OnRemove: (() -> ())?,
    OnClose: (() -> ())?,
}

local function _testRegistryKey(key: string): (boolean, string)
    local headers = { Authorization = `Bearer {key}` }

    local success, response = pcall(function()
        return HttpService:GetAsync(`{REGISTRY_URL}/health`, true, headers)
    end)

    if not success then
        local message = tostring(response)
        if message:find("HTTP 401") or message:find("HTTP 403") then
            return false, "Invalid key"
        elseif message:find("HTTP requests are not enabled") then
            return false, "HTTP requests are not enabled in Experience Settings"
        else
            return false, `Connection failed ({message:sub(1, 60)})`
        end
    end

    return true, "Valid"
end

local function _makeInfoSection(scope: Fusion.Scope): Fusion.Child
    return scope:New("Frame")({
        Name = "InfoContent",
        Size = UDim2.new(1, -20, 0, 0),
        Position = UDim2.fromOffset(10, 10),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,

        [Children] = {
            scope:New("UIListLayout")({
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 4),
            }),

            scope:New("TextLabel")({
                Name = "Paragraph1",
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
                TextColor3 = Color3.fromRGB(200, 200, 200),
                FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"),
                TextSize = 13,
                Text = "A <b>registry key</b> is required to publish and fetch "
                    .. "packages. It authenticates your plugin with the package "
                    .. "registry so only authorized users can read and write "
                    .. "packages.",
                RichText = true,
                TextWrapped = true,
                TextXAlignment = Enum.TextXAlignment.Left,
                LayoutOrder = 1,
            }),

            scope:New("TextLabel")({
                Name = "Paragraph2",
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
                TextColor3 = Color3.fromRGB(200, 200, 200),
                FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"),
                TextSize = 13,
                Text = "You can get a key from your team's registry administrator.",
                RichText = true,
                TextWrapped = true,
                TextXAlignment = Enum.TextXAlignment.Left,
                LayoutOrder = 2,
            }),
        },
    })
end

local function _makeKeyStatus(scope: Fusion.Scope, hasKey: Fusion.Value<boolean>, onRemove: () -> ()): Fusion.Child
    return scope:New("Frame")({
        Name = "KeyStatus",
        Size = UDim2.new(1, -20, 0, 28),
        Position = UDim2.fromOffset(10, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,

        [Children] = {
            scope:New("UICorner")({
                CornerRadius = UDim.new(0, 4),
            }),

            scope:New("UIStroke")({
                ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
                Color = Color3.fromRGB(80, 80, 80),
                Thickness = 1,
            }),

            scope:New("Frame")({
                Name = "Indicator",
                Size = UDim2.fromOffset(8, 8),
                Position = UDim2.new(0, 10, 0.5, 0),
                AnchorPoint = Vector2.new(0, 0.5),
                BackgroundColor3 = scope:Computed(function(use)
                    return if use(hasKey) then Color3.fromRGB(80, 200, 80) else Color3.fromRGB(200, 80, 80)
                end),

                [Children] = scope:New("UICorner")({
                    CornerRadius = UDim.new(1, 0),
                }),
            }),

            scope:New("TextLabel")({
                Name = "Label",
                Size = UDim2.new(1, -80, 1, 0),
                Position = UDim2.fromOffset(26, 0),
                BackgroundTransparency = 1,
                TextColor3 = Color3.fromRGB(180, 180, 180),
                FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"),
                TextSize = 12,
                Text = scope:Computed(function(use)
                    return if use(hasKey) then "Registry key saved" else "No registry key"
                end),
                TextXAlignment = Enum.TextXAlignment.Left,
            }),

            scope:New("TextButton")({
                Name = "RemoveButton",
                Size = UDim2.new(0, 0, 0, 20),
                AutomaticSize = Enum.AutomaticSize.X,
                Position = UDim2.new(1, -8, 0.5, 0),
                AnchorPoint = Vector2.new(1, 0.5),
                BackgroundColor3 = Color3.fromRGB(180, 50, 50),
                TextColor3 = Color3.fromRGB(255, 255, 255),
                FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
                TextSize = 10,
                Text = "Remove",
                Visible = hasKey,

                [Children] = {
                    scope:New("UICorner")({
                        CornerRadius = UDim.new(0, 4),
                    }),
                    scope:New("UIPadding")({
                        PaddingLeft = UDim.new(0, 8),
                        PaddingRight = UDim.new(0, 8),
                    }),
                },

                [OnEvent("MouseButton1Click")] = onRemove,
            }),
        },
    })
end

return function(scope: Fusion.Scope, props: SetKeyPromptProps): Fusion.Child
    local inputText = scope:Value("")
    local hasKey = scope:Value(props.CurrentKey ~= nil)
    local statusText = scope:Value("")
    local statusColor = scope:Value(Color3.fromRGB(180, 180, 180))
    local isTesting = scope:Value(false)

    local function setStatus(text: string, color: Color3)
        statusText:set(text)
        statusColor:set(color)
    end

    local function testKey()
        local key = Fusion.peek(inputText)
        if key == "" then
            setStatus("Enter a key first", Color3.fromRGB(200, 160, 60))
            return
        end

        isTesting:set(true)
        setStatus("Testing...", Color3.fromRGB(180, 180, 180))

        task.spawn(function()
            local valid, message = _testRegistryKey(key)
            isTesting:set(false)

            if valid then
                setStatus("Key is valid", Color3.fromRGB(80, 200, 80))
            else
                setStatus(message, Color3.fromRGB(200, 80, 80))
            end
        end)
    end

    local function saveKey()
        local key = Fusion.peek(inputText)
        if key == "" then
            setStatus("Enter a key first", Color3.fromRGB(200, 160, 60))
            return
        end

        isTesting:set(true)
        setStatus("Validating...", Color3.fromRGB(180, 180, 180))

        task.spawn(function()
            local valid, message = _testRegistryKey(key)
            isTesting:set(false)

            if valid then
                hasKey:set(true)
                inputText:set("")
                setStatus("Key saved", Color3.fromRGB(80, 200, 80))
                if props.OnSave then
                    props.OnSave(key)
                end
            else
                setStatus(`Invalid key ({message})`, Color3.fromRGB(200, 80, 80))
            end
        end)
    end

    local function removeKey()
        hasKey:set(false)
        inputText:set("")
        setStatus("Key removed", Color3.fromRGB(200, 160, 60))
        if props.OnRemove then
            props.OnRemove()
        end
    end

    return scope:New("Frame")({
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.fromRGB(46, 46, 46),
        BorderSizePixel = 0,

        [Children] = {
            -- Content area (everything above Save)
            scope:New("Frame")({
                Name = "Content",
                Size = UDim2.new(1, 0, 1, -46),
                BackgroundTransparency = 1,

                [Children] = {
                    scope:New("UIListLayout")({
                        SortOrder = Enum.SortOrder.LayoutOrder,
                        Padding = UDim.new(0, 6),
                    }),

                    -- Info section
                    scope:New("Frame")({
                        Name = "InfoSection",
                        Size = UDim2.new(1, 0, 0, 0),
                        AutomaticSize = Enum.AutomaticSize.Y,
                        BackgroundTransparency = 1,
                        LayoutOrder = 1,

                        [Children] = _makeInfoSection(scope),
                    }),

                    -- Key status indicator
                    scope:New("Frame")({
                        Name = "StatusSection",
                        Size = UDim2.new(1, 0, 0, 28),
                        BackgroundTransparency = 1,
                        LayoutOrder = 2,

                        [Children] = _makeKeyStatus(scope, hasKey, removeKey),
                    }),

                    -- Input field with Test button
                    scope:New("Frame")({
                        Name = "InputSection",
                        Size = UDim2.new(1, 0, 0, 30),
                        BackgroundTransparency = 1,
                        LayoutOrder = 3,

                        [Children] = {
                            scope:New("TextBox")({
                                Name = "Input",
                                Size = UDim2.new(1, -80, 1, 0),
                                Position = UDim2.fromOffset(10, 0),
                                BackgroundColor3 = Color3.fromRGB(30, 30, 30),
                                TextColor3 = Color3.fromRGB(255, 255, 255),
                                FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json"),
                                TextSize = 14,
                                Text = "",
                                PlaceholderText = "Enter registry key...",
                                PlaceholderColor3 = Color3.fromRGB(150, 150, 150),
                                TextXAlignment = Enum.TextXAlignment.Left,
                                ClearTextOnFocus = false,

                                [Children] = {
                                    scope:New("UICorner")({
                                        CornerRadius = UDim.new(0, 4),
                                    }),
                                    scope:New("UIPadding")({
                                        PaddingLeft = UDim.new(0, 8),
                                        PaddingRight = UDim.new(0, 8),
                                    }),
                                },

                                [OnChange("Text")] = function(newText: string)
                                    inputText:set(newText)
                                    if Fusion.peek(statusText) ~= "" then
                                        setStatus("", Color3.fromRGB(180, 180, 180))
                                    end
                                end,
                            }),

                            scope:New("TextButton")({
                                Name = "TestButton",
                                Size = UDim2.new(0, 54, 1, 0),
                                Position = UDim2.new(1, -10, 0, 0),
                                AnchorPoint = Vector2.new(1, 0),
                                BackgroundColor3 = Color3.fromRGB(60, 60, 60),
                                TextColor3 = Color3.fromRGB(255, 255, 255),
                                FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
                                TextSize = 12,
                                Text = "Test",

                                [Children] = scope:New("UICorner")({
                                    CornerRadius = UDim.new(0, 4),
                                }),

                                [OnEvent("MouseButton1Click")] = testKey,
                            }),
                        },
                    }),

                    -- Status message
                    scope:New("Frame")({
                        Name = "MessageSection",
                        Size = UDim2.new(1, 0, 0, 16),
                        BackgroundTransparency = 1,
                        LayoutOrder = 4,

                        [Children] = scope:New("TextLabel")({
                            Name = "Status",
                            Size = UDim2.new(1, -20, 1, 0),
                            Position = UDim2.fromOffset(10, 0),
                            BackgroundTransparency = 1,
                            TextColor3 = statusColor,
                            FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json"),
                            TextSize = 11,
                            Text = statusText,
                            TextXAlignment = Enum.TextXAlignment.Left,
                        }),
                    }),
                },
            }),

            -- Save button (anchored to bottom)
            scope:New("TextButton")({
                Name = "SaveButton",
                Size = UDim2.new(1, -20, 0, 36),
                Position = UDim2.new(0, 10, 1, -10),
                AnchorPoint = Vector2.new(0, 1),
                BackgroundColor3 = Color3.fromRGB(130, 230, 150),
                TextColor3 = Color3.fromRGB(0, 0, 0),
                FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
                TextSize = 14,
                Text = "Save",

                [Children] = scope:New("UICorner")({
                    CornerRadius = UDim.new(0, 4),
                }),

                [OnEvent("MouseButton1Click")] = saveKey,
            }),
        },
    })
end
