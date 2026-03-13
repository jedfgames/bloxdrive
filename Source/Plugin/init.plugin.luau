--[[

Plugin

Studio plugin for rbx-package-loader. Provides toolbar buttons to publish,
pull, and manage instance-based packages. Stores credentials in plugin
settings and uses the core RbxPackageLoader library for serialization,
deserialization, and merging.

--]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")

local Assets = require(script.Parent.Assets)
local AutoSync = require(script.Parent.AutoSync)
local CredentialStore = require(script.Parent.CredentialStore)
local Logger = require(script.Parent.Parent.RbxPackageLoader.Logger)
local PackagePublisher = require(script.Parent.PackagePublisher)
local PackagePuller = require(script.Parent.PackagePuller)
local RbxPackageLoader = require(script.Parent.Parent.RbxPackageLoader)
local Toolbar = require(script.Parent.Toolbar)

local PACKAGE_MARKER_NAME = ".rbx-package"
local PROMPT_WIDGET_ID = "PackageLoaderPrompt"
local TOOLBAR_NAME = "Packages"

local function _generateId(): string
    local chars = {}
    for _ = 1, 16 do
        table.insert(chars, string.format("%x", math.random(0, 15)))
    end
    return table.concat(chars)
end

local _promptWidget: DockWidgetPluginGui? = nil

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

local function _promptForInput(title: string, defaultValue: string?): string?
    if not _promptWidget then
        local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, true, 300, 100, 200, 80)
        _promptWidget = plugin:CreateDockWidgetPluginGuiAsync(PROMPT_WIDGET_ID, widgetInfo)
    end

    local widget = _promptWidget :: DockWidgetPluginGui

    -- Clear previous contents
    for _, child in widget:GetChildren() do
        child:Destroy()
    end

    widget.Title = title

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromScale(1, 1)
    frame.BackgroundColor3 = Color3.fromRGB(46, 46, 46)
    frame.BorderSizePixel = 0
    frame.Parent = widget

    local textBox = Instance.new("TextBox")
    textBox.Size = UDim2.new(1, -20, 0, 30)
    textBox.Position = UDim2.fromOffset(10, 10)
    textBox.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    textBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    textBox.Font = Enum.Font.Code
    textBox.TextSize = 14
    textBox.Text = defaultValue or ""
    textBox.PlaceholderText = "Enter value..."
    textBox.ClearTextOnFocus = false
    textBox.Parent = frame

    local submitButton = Instance.new("TextButton")
    submitButton.Size = UDim2.new(0, 80, 0, 25)
    submitButton.Position = UDim2.new(0.5, -40, 1, -35)
    submitButton.BackgroundColor3 = Color3.fromRGB(0, 120, 215)
    submitButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    submitButton.Font = Enum.Font.GothamBold
    submitButton.TextSize = 14
    submitButton.Text = "Submit"
    submitButton.Parent = frame

    local result: string? = nil
    local done = false

    submitButton.MouseButton1Click:Connect(function()
        local text = textBox.Text
        if text ~= "" then
            result = text
        end
        done = true
    end)

    widget.Enabled = true
    textBox:CaptureFocus()

    while not done do
        task.wait(0.1)
    end

    widget.Enabled = false
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

    local token = CredentialStore.getToken()
    if not token then
        Logger.warn('No auth token set. Use the "Set Token" button first.')
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
        local name = _promptForInput("Package Name", instance.Name)
        if not name then
            Logger.warn("Publish cancelled.")
            return
        end
        packageId = _generateId()
        packageName = name
    end

    Logger.print(`Publishing "{packageName}"...`)

    local result = PackagePublisher.publish(RbxPackageLoader.Serializer, {
        PackageId = packageId,
        PackageName = packageName,
        Root = instance,
        AuthToken = token,
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
    Name = "Pull",
    Label = "Pull",
    Description = "Pull the latest version of the selected package from the registry",
    Icon = Assets["Icons/CloudDownload.png"],
}, function()
    local instance = _getSelectedInstance()
    local token = CredentialStore.getToken()

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
        packageId = _promptForInput("Package ID")
        if not packageId then
            Logger.warn("Pull cancelled.")
            return
        end

        local parent = instance or game:GetService("Workspace")
        local folder = Instance.new("Folder")
        folder.Name = packageId
        folder.Parent = parent
        pullParent = folder
    end

    Logger.print(`Pulling "{packageId}"...`)

    local result = PackagePuller.pull(RbxPackageLoader, {
        PackageId = packageId,
        PackageName = packageName,
        Parent = pullParent,
        AuthToken = token,
    })

    if result.Success then
        local conflictMsg = ""
        if result.ConflictCount > 0 then
            local suffix = if result.ConflictCount == 1 then "conflict" else "conflicts"
            conflictMsg = ` with {result.ConflictCount} {suffix}`
        end

        Selection:Set({ pullParent })
        ChangeHistoryService:SetWaypoint(`Pulled {packageId} version {result.Version}`)
        Logger.print(`Pulled "{packageId}" version {result.Version}{conflictMsg}.`)
    else
        Logger.warn(`Failed to pull "{packageId}": {result.Error}`)
    end
end)

toolbar:CreateButton({
    Name = "SetToken",
    Label = "Set Token",
    Description = "Set or update the GitHub auth token for the package registry",
    Icon = Assets["Icons/Key.png"],
}, function()
    local currentToken = CredentialStore.getToken()
    local displayToken = if currentToken then string.rep("*", 20) else ""

    local newToken = _promptForInput("GitHub Auth Token", displayToken)
    if newToken and newToken ~= displayToken then
        CredentialStore.setToken(newToken)
        Logger.print("Auth token updated.")
    end
end)

AutoSync.start({
    CredentialStore = CredentialStore,
    Logger = Logger,
    PackagePublisher = PackagePublisher,
    PackagePuller = PackagePuller,
    RbxPackageLoader = RbxPackageLoader,
})

plugin.Unloading:Connect(function()
    AutoSync.stop()
end)

Logger.print("Plugin loaded.")
