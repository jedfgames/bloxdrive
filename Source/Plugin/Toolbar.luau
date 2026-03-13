--[[

Toolbar

Wrapper around Roblox's PluginToolbar that handles button creation with
the correct activation pattern. Buttons are immediately deactivated on
click and the callback is spawned in a separate thread to prevent the
button from staying highlighted.

--]]

local Toolbar = {}
Toolbar.__index = Toolbar

export type ToolbarButtonConfig = {
    Name: string,
    Label: string,
    Description: string,
    Icon: string,
}

function Toolbar.new(plugin: Plugin, toolbarName: string)
    assert(typeof(plugin) == "Instance" and plugin:IsA("Plugin"), `Expected "plugin" to be a Plugin instance.`)
    assert(typeof(toolbarName) == "string", `Expected "toolbarName" to be a string.`)

    local self = setmetatable({}, Toolbar)

    self.Plugin = plugin
    self.PluginToolbar = plugin:CreateToolbar(toolbarName)
    self.Buttons = {}

    return self
end

function Toolbar.CreateButton(self: Toolbar, config: ToolbarButtonConfig, onClick: () -> ())
    assert(typeof(config) == "table", `Expected "config" to be a ToolbarButtonConfig.`)
    assert(typeof(onClick) == "function", `Expected "onClick" to be a function.`)
    assert(not self.Buttons[config.Name], `A button with the name "{config.Name}" already exists in this toolbar.`)

    local button = self.PluginToolbar:CreateButton(config.Name, config.Description, config.Icon, config.Label)
    button.ClickableWhenViewportHidden = true
    button.Click:Connect(function()
        button:SetActive(false)
        task.spawn(onClick)
    end)

    self.Buttons[config.Name] = button

    return button
end

export type Toolbar = typeof(Toolbar.new(nil :: any, ""))

return Toolbar
