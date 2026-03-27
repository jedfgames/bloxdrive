--[[

init.plugin

Studio plugin for bloxdrive. Provides toolbar buttons to
publish, fetch, and manage instance-based packages. Stores credentials
in plugin settings and uses the core Bloxdrive library for
serialization, deserialization, and merging.

--]]

local RunService = game:GetService("RunService")

-- Only run in the edit DataModel, not play/server/client
if not RunService:IsEdit() then
    return
end

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")

local Fusion = require("@packages/Fusion")

local Assets = require("@self/Assets")
local AutoSync = require("@self/AutoSync")
local Bloxdrive = require("@bloxdrive")
local CredentialStore = require("@self/CredentialStore")
local Logger = require("@bloxdrive/Logger")
local PackagePublisher = require("@self/PackagePublisher")
local PackagePuller = require("@self/PackagePuller")
local PromptInput = require("@self/Components/PromptInput")
local SetKeyPrompt = require("@self/Components/SetKeyPrompt")
local Toolbar = require("@self/Toolbar")

local PACKAGE_MARKER_NAME = ".bloxdrive"
local PROMPT_WIDGET_ID = "BloxdrivePrompt"
local SET_KEY_WIDGET_ID = "BloxdriveSetKey"
local TOOLBAR_NAME = "Packages"

local function _generateId(): string
    local chars = {}
    for _ = 1, 16 do
        table.insert(chars, string.format("%x", math.random(0, 15)))
    end
    return table.concat(chars)
end

local _promptWidget: DockWidgetPluginGui? = nil
local _promptScope: Fusion.Scope? = nil
local _promptDone = false

local function _getSelectedInstance(): Instance?
    local selected = Selection:Get()
    if #selected ~= 1 then
        return nil
    end
    return selected[1]
end

local function _findPackageMarker(instance: Instance): StringValue?
    for _, child in instance:GetChildren() do
        if child:IsA("StringValue") and child.Name == PACKAGE_MARKER_NAME then
            return child
        end
    end
    return nil
end

local function _closePrompt()
    if _promptWidget then
        (_promptWidget :: DockWidgetPluginGui).Enabled = false
    end
    if _promptScope then
        Fusion.doCleanup(_promptScope)
        _promptScope = nil
    end
    _promptDone = true
end

local function _promptForInput(title: string, defaultValue: string?, placeholderText: string?): string?
    if not _promptWidget then
        local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, true, 300, 100, 200, 80)
        _promptWidget = plugin:CreateDockWidgetPluginGuiAsync(PROMPT_WIDGET_ID, widgetInfo)
    end

    local widget = _promptWidget :: DockWidgetPluginGui

    -- Toggle off if the prompt is already open with the same title
    if widget.Enabled and widget.Title == title then
        _closePrompt()
        return nil
    end

    -- Clean up previous prompt if switching to a different one
    _closePrompt()

    widget.Title = title

    local result: string? = nil
    _promptDone = false

    local scope = Fusion:scoped()
    _promptScope = scope
    local ui = PromptInput(scope, {
        DefaultValue = defaultValue,
        PlaceholderText = placeholderText or "Enter value...",
        OnSubmit = function(text: string)
            result = text
            _promptDone = true
        end,
    })

    ui.Parent = widget
    widget.Enabled = true

    -- Focus the text box after parenting
    local textBox = ui:FindFirstChild("Input")
    if textBox and textBox:IsA("TextBox") then
        textBox:CaptureFocus()
    end

    while not _promptDone do
        task.wait(0.1)
    end

    _closePrompt()
    return result
end

CredentialStore.init(plugin)

local toolbar = Toolbar.new(plugin, TOOLBAR_NAME)

toolbar:CreateButton({
    Name = "Publish",
    Label = "Publish",
    Description = "Publish the selected instance subtree as a package version",
    Icon = Assets["Icons/Publish.png"],
}, function()
    local instance = _getSelectedInstance()
    if not instance then
        Logger.warn("Select exactly one instance to publish.")
        return
    end

    local key = CredentialStore.getKey()
    if not key then
        Logger.warn('No registry key set. Use the "Set Key" button first.')
        return
    end

    local marker = _findPackageMarker(instance)
    local packageId: string
    local packageName: string

    if marker then
        local decoded = HttpService:JSONDecode(marker.Value)
        packageId = decoded.Id
        packageName = decoded.Name or packageId
    else
        local name = _promptForInput("Publish", instance.Name, "Enter package name...")
        if not name then
            Logger.warn("Publish cancelled.")
            return
        end
        packageId = _generateId()
        packageName = name
    end

    Logger.print(`Publishing "{packageName}"...`)

    local result = PackagePublisher.publish(Bloxdrive.Serializer, {
        PackageId = packageId,
        PackageName = packageName,
        Root = instance,
        RegistryKey = key,
    })

    if result.Success then
        if not marker then
            local newMarker = Instance.new("StringValue")
            newMarker.Name = PACKAGE_MARKER_NAME
            newMarker.Value = HttpService:JSONEncode({
                AutoPull = true,
                AutoPush = true,
                Id = packageId,
                Name = packageName,
                Version = result.Version,
            })
            newMarker.Parent = instance
        else
            local decoded = HttpService:JSONDecode(marker.Value)
            decoded.Version = result.Version
            marker.Value = HttpService:JSONEncode(decoded)
        end

        ChangeHistoryService:SetWaypoint(`Published {packageName} version {result.Version}`)
        Logger.print(`Published "{packageName}" version {result.Version} successfully.`)
    else
        Logger.warn(`Failed to publish "{packageId}": {result.Error}`)
    end
end)

toolbar:CreateButton({
    Name = "Fetch",
    Label = "Fetch",
    Description = "Fetch the latest version of the selected package from the registry",
    Icon = Assets["Icons/CloudDownload.png"],
}, function()
    local instance = _getSelectedInstance()
    local key = CredentialStore.getKey()

    -- If the selected instance already has a package marker, update
    -- in place. Otherwise, prompt for a package ID and create a new
    -- folder under the selected instance (or workspace if nothing
    -- is selected).
    local marker = if instance then _findPackageMarker(instance) else nil
    local packageId: string?
    local pullParent: Instance

    local packageName: string?

    if marker then
        local decoded = HttpService:JSONDecode(marker.Value)
        packageId = decoded.Id
        packageName = decoded.Name
        pullParent = instance :: Instance
    else
        packageId = _promptForInput("Fetch", nil, "Enter package ID...")
        if not packageId then
            Logger.warn("Fetch cancelled.")
            return
        end

        -- Validate the package exists before creating any instances
        local registryConfig = if key then { RegistryKey = key } else nil
        local registry = Bloxdrive.Registry.new(registryConfig)
        local metaSuccess, metadata = pcall(function()
            return registry:FetchMetadata(packageId)
        end)

        if not metaSuccess then
            Logger.warn(`Package "{packageId}" not found in registry.`)
            return
        end

        if metadata.Name then
            packageName = metadata.Name
        end

        local parent = instance or game:GetService("Workspace")
        local folder = Instance.new("Folder")
        folder.Name = packageName or packageId
        folder.Parent = parent
        pullParent = folder
    end

    Logger.print(`Pulling "{packageName or packageId}"...`)

    local result = PackagePuller.pull(Bloxdrive, {
        PackageId = packageId,
        PackageName = packageName,
        Parent = pullParent,
        RegistryKey = key,
    })

    if result.Success then
        local conflictMsg = ""
        if result.ConflictCount > 0 then
            local suffix = if result.ConflictCount == 1 then "conflict" else "conflicts"
            conflictMsg = ` with {result.ConflictCount} {suffix}`
        end

        Selection:Set({ pullParent })
        ChangeHistoryService:SetWaypoint(`Pulled {packageName or packageId} version {result.Version}`)
        Logger.print(`Pulled "{packageName or packageId}" version {result.Version}{conflictMsg}.`)
    else
        -- Clean up the folder if we created it for a fresh pull
        if not marker then
            pullParent:Destroy()
        end
        Logger.warn(`Failed to pull "{packageName or packageId}": {result.Error}`)
    end
end)

local _setKeyWidget: DockWidgetPluginGui? = nil
local _setKeyScope: Fusion.Scope? = nil

local function _closeSetKeyPrompt()
    if _setKeyWidget then
        (_setKeyWidget :: DockWidgetPluginGui).Enabled = false
    end
    if _setKeyScope then
        Fusion.doCleanup(_setKeyScope)
        _setKeyScope = nil
    end
end

toolbar:CreateButton({
    Name = "SetKey",
    Label = "Set Key",
    Description = "Set or update the registry key for the package registry",
    Icon = Assets["Icons/Key.png"],
}, function()
    if not _setKeyWidget then
        local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, true, 320, 300, 280, 250)
        _setKeyWidget = plugin:CreateDockWidgetPluginGuiAsync(SET_KEY_WIDGET_ID, widgetInfo)
    end

    local widget = _setKeyWidget :: DockWidgetPluginGui

    -- Toggle off if already open
    if widget.Enabled then
        _closeSetKeyPrompt()
        return
    end

    -- Clean up previous scope
    _closeSetKeyPrompt()

    widget.Title = "Set Key"

    local scope = Fusion:scoped()
    _setKeyScope = scope
    local ui = SetKeyPrompt(scope, {
        CurrentKey = CredentialStore.getKey(),
        OnSave = function(key: string)
            CredentialStore.setKey(key)
            Logger.print("Registry key updated.")
        end,
        OnRemove = function()
            CredentialStore.clearKey()
            Logger.print("Registry key removed.")
        end,
    })

    ui.Parent = widget
    widget.Enabled = true
end)

AutoSync.start({
    CredentialStore = CredentialStore,
    Logger = Logger,
    PackagePublisher = PackagePublisher,
    PackagePuller = PackagePuller,
    Bloxdrive = Bloxdrive,
})

plugin.Unloading:Connect(function()
    AutoSync.stop()
end)

Logger.print("Plugin loaded.", 2)
