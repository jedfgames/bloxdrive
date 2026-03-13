--[[

AutoSync

Manages automatic pulling and pushing of packages. Scans the DataModel
for `.rbx-package` markers on startup, pulls any with AutoPull enabled,
then sets up polling for remote changes and debounced pushing for local
changes.

AutoPull triggers immediately on plugin load and then on a polling
interval. AutoPush triggers on descendant changes with a 1-second
debounce timer that resets on each new change.

Uses a generation counter stored as a game attribute to detect stale
threads from prior plugin reloads. Every callback checks the current
generation before proceeding.

--]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")

local GENERATION_ATTR = "_RbxPackageLoaderSyncGeneration"
local PACKAGE_MARKER_NAME = ".rbx-package"
local PULL_POLL_SECONDS = 30
local PUSH_DEBOUNCE_SECONDS = 1

local AutoSync = {}

type MarkerInfo = {
    Id: string,
    Name: string?,
    Version: number,
    AutoPull: boolean,
    AutoPush: boolean,
    Marker: StringValue,
    Root: Instance,
}

type AutoSyncState = {
    CredentialStore: any,
    Generation: number,
    Logger: any,
    PackagePublisher: any,
    PackagePuller: any,
    RbxPackageLoader: any,
    Pulling: { [string]: boolean },
    Pushing: { [string]: boolean },
    PushEnabled: { [string]: boolean },
    PushTimers: { [string]: thread },
    PushConnections: { [string]: { RBXScriptConnection } },
    PollThread: thread?,
    Running: boolean,
}

local _state: AutoSyncState? = nil

local function _isCurrentGeneration(): boolean
    if not _state then
        return false
    end
    local current = game:GetAttribute(GENERATION_ATTR)
    return current == _state.Generation
end

--[=[
	Initializes the AutoSync system with the required dependencies and
	starts monitoring all existing packages in the DataModel.

	@param config table -- Dependencies: CredentialStore, Logger,
	PackagePublisher, PackagePuller, RbxPackageLoader
]=]
function AutoSync.start(config: {
    CredentialStore: any,
    Logger: any,
    PackagePublisher: any,
    PackagePuller: any,
    RbxPackageLoader: any,
})
    assert(config.CredentialStore, "Expected CredentialStore")
    assert(config.Logger, "Expected Logger")
    assert(config.PackagePublisher, "Expected PackagePublisher")
    assert(config.PackagePuller, "Expected PackagePuller")
    assert(config.RbxPackageLoader, "Expected RbxPackageLoader")

    -- Increment the generation counter to invalidate any zombie
    -- threads from prior plugin reloads
    local generation = (game:GetAttribute(GENERATION_ATTR) or 0) + 1
    game:SetAttribute(GENERATION_ATTR, generation)

    -- Clean up local state if any
    AutoSync.stop()

    _state = {
        CredentialStore = config.CredentialStore,
        Generation = generation,
        Logger = config.Logger,
        PackagePublisher = config.PackagePublisher,
        PackagePuller = config.PackagePuller,
        RbxPackageLoader = config.RbxPackageLoader,
        Pulling = {},
        Pushing = {},
        PushEnabled = {},
        PushTimers = {},
        PushConnections = {},
        PollThread = nil,
        Running = true,
    }

    local markers = _findAllMarkers()

    if #markers == 0 then
        return
    end

    -- Set up AutoPush listeners first (before pulls) but keep them
    -- disabled. They start recording connections but onChanged will
    -- bail out until PushEnabled is set.
    for _, info in markers do
        if info.AutoPush then
            _setupAutoPush(info)
        end
    end

    -- Initial pull for AutoPull packages
    for _, info in markers do
        if info.AutoPull then
            _autoPull(info)
        end
    end

    -- Enable AutoPush after a delay so deferred events from the
    -- initial pull have time to fire and be ignored
    task.delay(2, function()
        if not _isCurrentGeneration() then
            return
        end

        local state = _state :: AutoSyncState

        for _, info in markers do
            if info.AutoPush then
                state.PushEnabled[info.Id] = true
            end
        end
    end)

    -- Start polling for AutoPull packages
    _startPolling(markers)
end

--[=[
	Stops all AutoSync activity, cancels timers, and disconnects
	listeners.
]=]
function AutoSync.stop()
    if not _state then
        return
    end

    _state.Running = false

    -- Cancel all push timers
    for id, timer in _state.PushTimers do
        task.cancel(timer)
        _state.PushTimers[id] = nil
    end

    -- Disconnect all push listeners
    for id, connections in _state.PushConnections do
        for _, connection in connections do
            connection:Disconnect()
        end
        _state.PushConnections[id] = nil
    end

    -- Cancel poll thread
    if _state.PollThread then
        task.cancel(_state.PollThread)
        _state.PollThread = nil
    end

    _state = nil
end

function _findAllMarkers(): { MarkerInfo }
    local markers: { MarkerInfo } = {}

    local function scan(instance: Instance)
        for _, child in instance:GetChildren() do
            if child:IsA("StringValue") and child.Name == PACKAGE_MARKER_NAME then
                local decodeSuccess, decoded = pcall(function()
                    return HttpService:JSONDecode(child.Value)
                end)

                if decodeSuccess and decoded.Id then
                    table.insert(markers, {
                        AutoPull = decoded.AutoPull == true,
                        AutoPush = decoded.AutoPush == true,
                        Id = decoded.Id,
                        Marker = child :: StringValue,
                        Name = decoded.Name,
                        Root = instance,
                        Version = decoded.Version or 0,
                    })
                end
            end

            scan(child)
        end
    end

    scan(game)
    return markers
end

function _autoPull(info: MarkerInfo)
    local state = _state :: AutoSyncState

    if not _isCurrentGeneration() then
        return
    end

    local token = state.CredentialStore.getToken()
    if not token then
        return
    end

    -- Fetch metadata via the GitHub API (not raw URLs) to avoid CDN
    -- caching and check if there's actually a newer version before
    -- pulling.
    local registryConfig = { AuthToken = token }
    local registry = state.RbxPackageLoader.Registry.new(registryConfig)

    local metaSuccess, metadata = pcall(function()
        return registry:FetchMetadata(info.Id)
    end)

    if not metaSuccess then
        state.Logger.warn(`[AutoPull] Failed to check metadata for "{info.Id}": {metadata}`)
        return
    end

    if metadata.LatestVersion <= info.Version then
        return
    end

    state.Logger.print(
        `[AutoPull] Updating "{info.Name or info.Id}" from version {info.Version} to {metadata.LatestVersion}...`
    )

    -- Suppress AutoPush while pulling to avoid feedback loop
    state.Pulling[info.Id] = true

    local result = state.PackagePuller.pull(state.RbxPackageLoader, {
        PackageId = info.Id,
        PackageName = info.Name,
        Parent = info.Root,
        AuthToken = token,
    })

    -- Keep pulling flag set briefly for deferred events, then cancel
    -- any push timers that snuck through
    task.delay(2, function()
        if not _isCurrentGeneration() then
            return
        end

        state.Pulling[info.Id] = nil

        if state.PushTimers[info.Id] then
            task.cancel(state.PushTimers[info.Id])
            state.PushTimers[info.Id] = nil
        end
    end)

    if result.Success then
        info.Version = result.Version
        ChangeHistoryService:SetWaypoint(`AutoPull {info.Name or info.Id} version {result.Version}`)
        state.Logger.print(`[AutoPull] Updated "{info.Name or info.Id}" to version {result.Version}.`)
    else
        state.Logger.warn(`[AutoPull] Failed to pull "{info.Id}": {result.Error}`)
    end
end

function _setupAutoPush(info: MarkerInfo)
    local state = _state :: AutoSyncState
    local connections: { RBXScriptConnection } = {}

    local function onChanged()
        if not _isCurrentGeneration() then
            return
        end

        -- Ignore changes until AutoPush is enabled (after initial pull
        -- settles)
        if not state.PushEnabled[info.Id] then
            return
        end

        -- Ignore changes caused by AutoPull
        if state.Pulling[info.Id] then
            return
        end

        -- Ignore changes while a push is in progress
        if state.Pushing[info.Id] then
            return
        end

        -- Cancel existing timer for this package
        if state.PushTimers[info.Id] then
            task.cancel(state.PushTimers[info.Id])
        end

        -- Start new debounce timer
        state.PushTimers[info.Id] = task.delay(PUSH_DEBOUNCE_SECONDS, function()
            state.PushTimers[info.Id] = nil

            if not _isCurrentGeneration() then
                return
            end

            _autoPush(info)
        end)
    end

    table.insert(connections, info.Root.DescendantAdded:Connect(onChanged))
    table.insert(connections, info.Root.DescendantRemoving:Connect(onChanged))

    -- Listen for property changes on all descendants
    local function connectPropertyChanges(instance: Instance)
        if instance.Name == PACKAGE_MARKER_NAME then
            return
        end
        table.insert(connections, instance.Changed:Connect(onChanged))
    end

    for _, descendant in info.Root:GetDescendants() do
        connectPropertyChanges(descendant)
    end

    -- Connect to future descendants
    table.insert(
        connections,
        info.Root.DescendantAdded:Connect(function(descendant)
            connectPropertyChanges(descendant)
        end)
    )

    state.PushConnections[info.Id] = connections
end

function _autoPush(info: MarkerInfo)
    local state = _state :: AutoSyncState

    if not _isCurrentGeneration() then
        return
    end

    if state.Pulling[info.Id] then
        return
    end

    local token = state.CredentialStore.getToken()
    if not token then
        return
    end

    state.Pushing[info.Id] = true
    state.Logger.print(`[AutoPush] Publishing "{info.Name or info.Id}"...`)

    local result = state.PackagePublisher.publish(state.RbxPackageLoader.Serializer, {
        PackageId = info.Id,
        PackageName = info.Name or info.Id,
        Root = info.Root,
        AuthToken = token,
    })

    state.Pushing[info.Id] = nil

    if not _isCurrentGeneration() then
        return
    end

    if result.Success then
        -- Suppress push events from marker update
        state.Pulling[info.Id] = true
        local decoded = HttpService:JSONDecode(info.Marker.Value)
        decoded.Version = result.Version
        info.Marker.Value = HttpService:JSONEncode(decoded)
        info.Version = result.Version

        task.delay(1, function()
            if not _isCurrentGeneration() then
                return
            end

            state.Pulling[info.Id] = nil

            if state.PushTimers[info.Id] then
                task.cancel(state.PushTimers[info.Id])
                state.PushTimers[info.Id] = nil
            end
        end)

        ChangeHistoryService:SetWaypoint(`AutoPush {info.Name or info.Id} version {result.Version}`)
        state.Logger.print(`[AutoPush] Published "{info.Name or info.Id}" version {result.Version}.`)
    else
        state.Logger.warn(`[AutoPush] Failed to publish "{info.Id}": {result.Error}`)
    end
end

function _startPolling(markers: { MarkerInfo })
    local state = _state :: AutoSyncState

    local autoPullMarkers: { MarkerInfo } = {}
    for _, info in markers do
        if info.AutoPull then
            table.insert(autoPullMarkers, info)
        end
    end

    if #autoPullMarkers == 0 then
        return
    end

    state.PollThread = task.spawn(function()
        while state.Running and _isCurrentGeneration() do
            task.wait(PULL_POLL_SECONDS)

            if not state.Running or not _isCurrentGeneration() then
                break
            end

            for _, info in autoPullMarkers do
                _autoPull(info)
            end
        end
    end)
end

return AutoSync
