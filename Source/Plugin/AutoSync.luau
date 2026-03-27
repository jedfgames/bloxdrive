--[[

AutoSync

Manages automatic pulling and pushing of packages. Scans the DataModel
for `.bloxdrive` markers on startup and watches for new markers added
at runtime. Pulls any with AutoPull enabled, then sets up polling for
remote changes and debounced pushing for local changes.

AutoPull triggers immediately on plugin load and then on a polling
interval. AutoPush triggers on descendant changes with a 1-second
debounce timer that resets on each new change.

Uses a generation counter stored as a game attribute to detect stale
threads from prior plugin reloads. Every callback checks the current
generation before proceeding.

Supports multiple instances of the same package in different locations.
Each instance is tracked independently with its own push connections
and timers, but pull/push locks are shared per package ID to prevent
concurrent operations on the same registry package.

Marker protection: `.bloxdrive` markers are strictly validated and
locked down. Moving a marker outside its root, renaming it, tampering
with its value, or creating invalid markers all result in the marker
being destroyed and the package unregistered. Only one `.bloxdrive`
marker is allowed per parent instance.

--]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")

local GENERATION_ATTR = "_BloxdriveSyncGeneration"
local PACKAGE_MARKER_NAME = ".bloxdrive"
local PULL_POLL_SECONDS = 5
local PUSH_DEBOUNCE_SECONDS = 1

local AutoSync = {}

type MarkerInfo = {
    Id: string,
    Key: string,
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
    NextKey: number,
    PackagePublisher: any,
    PackagePuller: any,
    Bloxdrive: any,
    PendingPull: { [string]: boolean },
    PendingPush: { [string]: boolean },
    Pulling: { [string]: boolean },
    Pushing: { [string]: boolean },
    PushEnabled: { [string]: boolean },
    PushTimers: { [string]: thread },
    PushConnections: { [string]: { RBXScriptConnection } },
    RegisteredPackages: { [string]: MarkerInfo },
    PollThread: thread?,
    MarkerWatcher: RBXScriptConnection?,
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

local function _generateKey(): string
    local state = _state :: AutoSyncState
    local key = `reg_{state.NextKey}`
    state.NextKey += 1
    return key
end

-- Validates that a marker's JSON value has the required structure
-- and field types. Returns the decoded table on success, nil on
-- failure.
local function _validateMarkerValue(value: string): { [string]: any }?
    local decodeSuccess, decoded = pcall(function()
        return HttpService:JSONDecode(value)
    end)

    if not decodeSuccess or type(decoded) ~= "table" then
        return nil
    end

    -- Required: Id must be a non-empty string
    if type(decoded.Id) ~= "string" or #decoded.Id == 0 then
        return nil
    end

    -- Required: Version must be a non-negative number
    if type(decoded.Version) ~= "number" or decoded.Version < 0 then
        return nil
    end

    -- Optional but must be correct type if present
    if decoded.Name ~= nil and type(decoded.Name) ~= "string" then
        return nil
    end

    if decoded.AutoPull ~= nil and type(decoded.AutoPull) ~= "boolean" then
        return nil
    end

    if decoded.AutoPush ~= nil and type(decoded.AutoPush) ~= "boolean" then
        return nil
    end

    -- Reject any unexpected keys
    local ALLOWED_KEYS = {
        AutoPull = true,
        AutoPush = true,
        Id = true,
        Name = true,
        Version = true,
    }
    for key in decoded do
        if not ALLOWED_KEYS[key] then
            return nil
        end
    end

    return decoded
end

-- Destroys an invalid marker and logs a warning.
local function _destroyInvalidMarker(marker: StringValue, reason: string)
    if not _state then
        return
    end

    local state = _state :: AutoSyncState
    local ok, path = pcall(function()
        return marker:GetFullName()
    end)
    state.Logger.warn(
        `[AutoSync] Destroyed invalid ".bloxdrive" marker ({reason}). Was at "{if ok then path else "unknown"}".`
    )

    -- Suppress push events from the destruction
    pcall(function()
        marker:Destroy()
    end)
end

--[=[
    Initializes the AutoSync system with the required dependencies and
    starts monitoring all existing packages in the DataModel. Also
    watches for new `.bloxdrive` markers added at runtime.

    @param config table -- Dependencies: CredentialStore, Logger,
    PackagePublisher, PackagePuller, Bloxdrive
]=]
function AutoSync.start(config: {
    CredentialStore: any,
    Logger: any,
    PackagePublisher: any,
    PackagePuller: any,
    Bloxdrive: any,
})
    assert(config.CredentialStore, "Expected CredentialStore")
    assert(config.Logger, "Expected Logger")
    assert(config.PackagePublisher, "Expected PackagePublisher")
    assert(config.PackagePuller, "Expected PackagePuller")
    assert(config.Bloxdrive, "Expected Bloxdrive")

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
        NextKey = 1,
        PackagePublisher = config.PackagePublisher,
        PackagePuller = config.PackagePuller,
        Bloxdrive = config.Bloxdrive,
        PendingPull = {},
        PendingPush = {},
        Pulling = {},
        Pushing = {},
        PushEnabled = {},
        PushTimers = {},
        PushConnections = {},
        RegisteredPackages = {},
        PollThread = nil,
        MarkerWatcher = nil,
        Running = true,
    }

    -- Scan for existing packages, validate, and register them
    local markers = _findAllMarkers()

    for _, info in markers do
        _registerPackage(info)
    end

    -- Watch for new markers added at runtime (e.g. after a manual
    -- pull or when the user creates a new package)
    _startMarkerWatcher()

    -- Start the poll loop (handles both pulling and re-scanning)
    _startPolling()
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
    for key, timer in _state.PushTimers do
        task.cancel(timer)
        _state.PushTimers[key] = nil
    end

    -- Disconnect all push listeners
    for key, connections in _state.PushConnections do
        for _, connection in connections do
            connection:Disconnect()
        end
        _state.PushConnections[key] = nil
    end

    -- Disconnect marker watcher
    if _state.MarkerWatcher then
        _state.MarkerWatcher:Disconnect()
        _state.MarkerWatcher = nil
    end

    -- Cancel poll thread
    if _state.PollThread then
        task.cancel(_state.PollThread)
        _state.PollThread = nil
    end

    _state = nil
end

function _isMarkerRegistered(marker: StringValue): boolean
    local state = _state :: AutoSyncState
    for _, info in state.RegisteredPackages do
        if info.Marker == marker then
            return true
        end
    end
    return false
end

function _findKeyForMarker(marker: StringValue): string?
    local state = _state :: AutoSyncState
    for key, info in state.RegisteredPackages do
        if info.Marker == marker then
            return key
        end
    end
    return nil
end

function _unregisterPackage(key: string)
    local state = _state :: AutoSyncState
    local info = state.RegisteredPackages[key]
    if not info then
        return
    end

    state.Logger.print(
        `[AutoSync] Unregistered package "{info.Name or info.Id}" (was at {info.Root:GetFullName()}).`,
        2
    )

    -- Clean up push connections
    if state.PushConnections[key] then
        for _, connection in state.PushConnections[key] do
            connection:Disconnect()
        end
        state.PushConnections[key] = nil
    end

    -- Cancel push timer
    if state.PushTimers[key] then
        task.cancel(state.PushTimers[key])
        state.PushTimers[key] = nil
    end

    state.PushEnabled[key] = nil
    state.RegisteredPackages[key] = nil

    -- Clear pending flags if no more instances of this package
    -- are registered
    local hasOtherInstances = false
    for _, regInfo in state.RegisteredPackages do
        if regInfo.Id == info.Id then
            hasOtherInstances = true
            break
        end
    end
    if not hasOtherInstances then
        state.PendingPull[info.Id] = nil
        state.PendingPush[info.Id] = nil
        state.Pulling[info.Id] = nil
        state.Pushing[info.Id] = nil
    end
end

function _isValidPackageRoot(instance: Instance): boolean
    -- Reject top-level services and game itself as package roots
    if instance == game then
        return false
    end
    if instance.Parent == game then
        return false
    end
    return true
end

function _registerPackage(info: MarkerInfo)
    local state = _state :: AutoSyncState

    -- Skip if this exact marker instance is already registered
    if _isMarkerRegistered(info.Marker) then
        return
    end

    -- Don't register if the root is a top-level service or game
    if not _isValidPackageRoot(info.Root) then
        _destroyInvalidMarker(
            info.Marker,
            `root is a top-level service ({info.Root.Name}), marker must be inside a folder`
        )
        return
    end

    -- Check for duplicate markers under the same parent: only one
    -- .bloxdrive is allowed per parent instance
    for _, existing in state.RegisteredPackages do
        if existing.Root == info.Root and existing.Marker ~= info.Marker then
            _destroyInvalidMarker(
                info.Marker,
                `duplicate marker under "{info.Root:GetFullName()}" (already tracking "{existing.Id}")`
            )
            return
        end
    end

    -- Assign a unique registration key
    info.Key = _generateKey()

    state.RegisteredPackages[info.Key] = info
    state.Logger.print(
        `[AutoSync] Registered package "{info.Name or info.Id}" at {info.Root:GetFullName()} (version {info.Version}).`,
        2
    )

    -- Fix folder name if it's using the raw package ID but has a
    -- human-readable name
    if info.Name and info.Root.Name == info.Id and info.Root.Name ~= info.Name then
        info.Root.Name = info.Name
        state.Logger.print(`[AutoSync] Renamed package root from "{info.Id}" to "{info.Name}".`, 2)
    end

    -- Lock down the marker: watch for reparenting, renaming, and
    -- value tampering
    _lockdownMarker(info)

    -- Set up AutoPush listeners (but keep them disabled until after
    -- the initial pull settles)
    if info.AutoPush then
        _setupAutoPush(info)
    end

    -- Reconcile on startup: verify local content matches the
    -- registry for the claimed version, then check for updates
    if info.AutoPull then
        state.Pulling[info.Id] = true
        _reconcilePackage(info)
        _autoPull(info)
        task.delay(2, function()
            if not _isCurrentGeneration() then
                return
            end
            local currentState = _state :: AutoSyncState
            currentState.Pulling[info.Id] = nil
            -- Cancel any push timers that fired during reconciliation
            for _, regInfo in currentState.RegisteredPackages do
                if regInfo.Id == info.Id and currentState.PushTimers[regInfo.Key] then
                    task.cancel(currentState.PushTimers[regInfo.Key])
                    currentState.PushTimers[regInfo.Key] = nil
                end
            end
        end)
    end

    -- Enable AutoPush after a delay so deferred events from the
    -- initial pull/reconciliation have time to fire and be ignored
    if info.AutoPush then
        local key = info.Key
        task.delay(3, function()
            if not _isCurrentGeneration() then
                return
            end

            local currentState = _state :: AutoSyncState
            currentState.PushEnabled[key] = true
        end)
    end
end

function _lockdownMarker(info: MarkerInfo)
    local state = _state :: AutoSyncState
    local key = info.Key

    if not state.PushConnections[key] then
        state.PushConnections[key] = {}
    end
    local connections = state.PushConnections[key]

    -- Destroy and unregister if marker is moved away from its root
    -- or destroyed. AncestryChanged fires for any ancestor change,
    -- so we only react when the marker itself was reparented. Moving
    -- the entire package folder to a new location is fine — the
    -- marker stays parented to the same root.
    table.insert(
        connections,
        info.Marker.AncestryChanged:Connect(function(child, newParent)
            if not _isCurrentGeneration() then
                return
            end

            if child ~= info.Marker then
                return
            end

            if newParent == info.Root then
                return
            end

            -- Marker was moved or destroyed
            _unregisterPackage(key)

            -- If it was moved (not destroyed), destroy it
            if newParent ~= nil then
                _destroyInvalidMarker(info.Marker, "marker was moved outside its package root")
            end
        end)
    )

    -- Destroy and unregister if marker is renamed
    table.insert(
        connections,
        info.Marker:GetPropertyChangedSignal("Name"):Connect(function()
            if not _isCurrentGeneration() then
                return
            end

            if info.Marker.Name ~= PACKAGE_MARKER_NAME then
                _unregisterPackage(key)
                _destroyInvalidMarker(info.Marker, `marker was renamed to "{info.Marker.Name}"`)
            end
        end)
    )

    -- Validate if marker value is changed externally (not by us).
    -- If the value becomes invalid, destroy the marker. If the Id
    -- changes, that's tampering — destroy it. Only Version changes
    -- from our own code are expected.
    table.insert(
        connections,
        info.Marker:GetPropertyChangedSignal("Value"):Connect(function()
            if not _isCurrentGeneration() then
                return
            end

            -- Ignore value changes during pull/push (we change the
            -- value ourselves)
            if state.Pulling[info.Id] or state.Pushing[info.Id] then
                return
            end

            local decoded = _validateMarkerValue(info.Marker.Value)
            if not decoded then
                _unregisterPackage(key)
                _destroyInvalidMarker(info.Marker, "marker value was changed to invalid JSON")
                return
            end

            -- Id must never change — that's tampering
            if decoded.Id ~= info.Id then
                _unregisterPackage(key)
                _destroyInvalidMarker(info.Marker, `marker Id was changed from "{info.Id}" to "{decoded.Id}"`)
                return
            end
        end)
    )
end

function _findAllMarkers(): { MarkerInfo }
    local markers: { MarkerInfo } = {}

    local function scan(instance: Instance)
        for _, child in instance:GetChildren() do
            if child:IsA("StringValue") and child.Name == PACKAGE_MARKER_NAME then
                local decoded = _validateMarkerValue(child.Value)
                if decoded then
                    table.insert(markers, {
                        AutoPull = decoded.AutoPull == true,
                        AutoPush = decoded.AutoPush == true,
                        Id = decoded.Id,
                        Key = "",
                        Marker = child :: StringValue,
                        Name = decoded.Name,
                        Root = instance,
                        Version = decoded.Version or 0,
                    })
                else
                    _destroyInvalidMarker(child :: StringValue, "invalid marker value on startup scan")
                end
            end

            scan(child)
        end
    end

    scan(game)
    return markers
end

function _startMarkerWatcher()
    local state = _state :: AutoSyncState

    state.MarkerWatcher = game.DescendantAdded:Connect(function(descendant)
        if not _isCurrentGeneration() then
            return
        end

        if not descendant:IsA("StringValue") then
            return
        end

        if descendant.Name ~= PACKAGE_MARKER_NAME then
            return
        end

        -- Wait a frame for the parent to be set
        task.defer(function()
            if not _isCurrentGeneration() then
                return
            end

            local parent = descendant.Parent
            if not parent then
                return
            end

            -- Skip if this exact marker is already registered
            if _isMarkerRegistered(descendant :: StringValue) then
                return
            end

            local decoded = _validateMarkerValue(descendant.Value)
            if not decoded then
                _destroyInvalidMarker(descendant :: StringValue, "newly added marker has invalid value")
                return
            end

            local info: MarkerInfo = {
                AutoPull = decoded.AutoPull == true,
                AutoPush = decoded.AutoPush == true,
                Id = decoded.Id,
                Key = "",
                Marker = descendant :: StringValue,
                Name = decoded.Name,
                Root = parent,
                Version = decoded.Version or 0,
            }

            _registerPackage(info)
        end)
    end)
end

-- Drains pending operations for a package after a pull or push
-- completes. If a push was queued while pulling (or vice versa),
-- this picks up the pending work so nothing gets dropped.
function _drainPendingOperations(packageId: string)
    local state = _state :: AutoSyncState

    if not _isCurrentGeneration() then
        return
    end

    -- Pull takes priority over push since we want to merge
    -- remote changes before pushing local ones
    if state.PendingPull[packageId] then
        state.PendingPull[packageId] = nil
        state.PendingPush[packageId] = nil

        for _, regInfo in state.RegisteredPackages do
            if regInfo.Id == packageId and regInfo.AutoPull then
                _autoPull(regInfo)
                break
            end
        end
        return
    end

    if state.PendingPush[packageId] then
        state.PendingPush[packageId] = nil

        for _, regInfo in state.RegisteredPackages do
            if regInfo.Id == packageId and regInfo.AutoPush then
                _autoPush(regInfo)
                break
            end
        end
    end
end

-- Reconciles local package content against the registry version.
-- If the local tree doesn't match what's stored for the claimed
-- version, forces a re-pull to fix drift. This runs once on
-- startup for each registered package.
function _reconcilePackage(info: MarkerInfo)
    local state = _state :: AutoSyncState

    if not _isCurrentGeneration() then
        return
    end

    -- Skip reconciliation for version 0 (fresh install, autoPull
    -- will handle it)
    if info.Version == 0 then
        return
    end

    local key = state.CredentialStore.getKey()
    if not key then
        return
    end

    local registryConfig = { RegistryKey = key }
    local registry = state.Bloxdrive.Registry.new(registryConfig)

    -- Fetch the registry tree for the claimed version
    local fetchSuccess, registryTree = pcall(function()
        return registry:FetchVersion(info.Id, info.Version)
    end)

    if not fetchSuccess then
        state.Logger.warn(
            `[AutoSync] Failed to fetch version {info.Version} of "{info.Name or info.Id}" for reconciliation: {registryTree}`
        )
        return
    end

    -- Serialize local tree
    local localTree = state.Bloxdrive.Serializer.serialize(info.Root)

    -- Compare using TreeUtils.deepEqual
    local TreeUtils = state.Bloxdrive.TreeUtils
    if TreeUtils.deepEqual(localTree, registryTree) then
        return
    end

    state.Logger.print(
        `[AutoSync] Reconciling "{info.Name or info.Id}" at {info.Root:GetFullName()} (local content doesn't match registry version {info.Version}).`,
        2
    )

    -- Local has drifted from the registry. Push local changes
    -- as a new version so both sides converge.
    if info.AutoPush and not state.Pushing[info.Id] then
        _autoPush(info)
    end
end

function _autoPull(info: MarkerInfo)
    local state = _state :: AutoSyncState

    if not _isCurrentGeneration() then
        return
    end

    -- Queue pull if we're currently pushing this package
    if state.Pushing[info.Id] then
        state.PendingPull[info.Id] = true
        return
    end

    local key = state.CredentialStore.getKey()
    if not key then
        return
    end

    -- Fetch metadata via the registry API to avoid CDN caching and
    -- check if there's actually a newer version before pulling.
    local registryConfig = { RegistryKey = key }
    local registry = state.Bloxdrive.Registry.new(registryConfig)

    local metaSuccess, metadata = pcall(function()
        return registry:FetchMetadata(info.Id)
    end)

    if not metaSuccess then
        state.Logger.warn(`[AutoPull] Failed to check metadata for "{info.Id}": {metadata}`)
        return
    end

    if metadata.LatestVersion <= info.Version then
        -- Even when versions match, reconcile to detect race
        -- conditions where two publishers wrote different content
        -- to the same version number
        _reconcilePackage(info)
        return
    end

    state.Logger.print(
        `[AutoPull] Updating "{info.Name or info.Id}" at {info.Root:GetFullName()} from version {info.Version} to {metadata.LatestVersion}...`
    )

    -- Suppress AutoPush while pulling to avoid feedback loop
    state.Pulling[info.Id] = true

    local result = state.PackagePuller.pull(state.Bloxdrive, {
        PackageId = info.Id,
        PackageName = info.Name,
        Parent = info.Root,
        RegistryKey = key,
    })

    if result.Success then
        info.Version = result.Version
        ChangeHistoryService:SetWaypoint(`AutoPull {info.Name or info.Id} version {result.Version}`)
        state.Logger.print(
            `[AutoPull] Updated "{info.Name or info.Id}" at {info.Root:GetFullName()} to version {result.Version}.`
        )
    else
        state.Logger.warn(`[AutoPull] Failed to pull "{info.Id}": {result.Error}`)
    end

    -- Keep pulling flag set briefly for deferred events, then
    -- cancel any push timers that snuck through, and drain
    -- pending operations
    task.delay(2, function()
        if not _isCurrentGeneration() then
            return
        end

        state.Pulling[info.Id] = nil

        -- Cancel push timers for ALL instances of this package
        for _, regInfo in state.RegisteredPackages do
            if regInfo.Id == info.Id and state.PushTimers[regInfo.Key] then
                task.cancel(state.PushTimers[regInfo.Key])
                state.PushTimers[regInfo.Key] = nil
            end
        end

        -- Clear any pending push that was queued during the pull
        -- since the pull already brought us up to date. Only
        -- drain if there were local changes AFTER the pull.
        state.PendingPush[info.Id] = nil
        _drainPendingOperations(info.Id)
    end)
end

function _setupAutoPush(info: MarkerInfo)
    local state = _state :: AutoSyncState
    local key = info.Key
    local connections: { RBXScriptConnection } = {}

    local function onChanged()
        if not _isCurrentGeneration() then
            return
        end

        -- Ignore changes until AutoPush is enabled (after initial
        -- pull settles)
        if not state.PushEnabled[key] then
            return
        end

        -- Queue a push if we're busy pulling or pushing
        if state.Pulling[info.Id] or state.Pushing[info.Id] then
            state.PendingPush[info.Id] = true
            return
        end

        -- Cancel existing timer for this instance
        if state.PushTimers[key] then
            task.cancel(state.PushTimers[key])
        end

        -- Start new debounce timer
        state.PushTimers[key] = task.delay(PUSH_DEBOUNCE_SECONDS, function()
            state.PushTimers[key] = nil

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

    -- Store in PushConnections (marker lockdown connections are
    -- already stored there by _lockdownMarker)
    if state.PushConnections[key] then
        for _, conn in connections do
            table.insert(state.PushConnections[key], conn)
        end
    else
        state.PushConnections[key] = connections
    end
end

function _autoPush(info: MarkerInfo)
    local state = _state :: AutoSyncState

    if not _isCurrentGeneration() then
        return
    end

    -- Queue push if we're busy with this package
    if state.Pulling[info.Id] or state.Pushing[info.Id] then
        state.PendingPush[info.Id] = true
        return
    end

    local key = state.CredentialStore.getKey()
    if not key then
        return
    end

    -- Verify the root still has children before pushing
    local childCount = #info.Root:GetChildren()
    if childCount <= 1 then
        state.Logger.warn(
            `[AutoPush] Skipping publish for "{info.Name or info.Id}" because root has only {childCount} children (expected more than just the marker).`
        )
        return
    end

    -- Pull-before-push: if the remote has a newer version, merge
    -- it into local first so we don't overwrite changes from other
    -- places. This is the key to multi-place collaboration.
    local registryConfig = { RegistryKey = key }
    local registry = state.Bloxdrive.Registry.new(registryConfig)
    local metaSuccess, metadata = pcall(function()
        return registry:FetchMetadata(info.Id)
    end)

    if metaSuccess and metadata.LatestVersion > info.Version then
        state.Logger.print(
            `[AutoPush] Remote version {metadata.LatestVersion} is ahead of local version {info.Version} for "{info.Name or info.Id}". Merging before push...`
        )

        -- Set pulling flag to suppress push events from the merge
        state.Pulling[info.Id] = true

        local pullResult = state.PackagePuller.pull(state.Bloxdrive, {
            PackageId = info.Id,
            PackageName = info.Name,
            Parent = info.Root,
            RegistryKey = key,
        })

        state.Pulling[info.Id] = nil

        -- Cancel any push timers that fired during the merge
        for _, regInfo in state.RegisteredPackages do
            if regInfo.Id == info.Id and state.PushTimers[regInfo.Key] then
                task.cancel(state.PushTimers[regInfo.Key])
                state.PushTimers[regInfo.Key] = nil
            end
        end
        state.PendingPush[info.Id] = nil

        if pullResult.Success then
            info.Version = pullResult.Version

            -- Update marker
            state.Pushing[info.Id] = true
            local decoded = HttpService:JSONDecode(info.Marker.Value)
            decoded.Version = pullResult.Version
            info.Marker.Value = HttpService:JSONEncode(decoded)
            state.Pushing[info.Id] = nil

            ChangeHistoryService:SetWaypoint(`AutoPush merged {info.Name or info.Id} version {pullResult.Version}`)
        else
            state.Logger.warn(
                `[AutoPush] Failed to merge remote changes for "{info.Id}" before push: {pullResult.Error}`
            )
            -- Continue with the push anyway — better to publish local
            -- state than to silently drop the user's changes
        end
    end

    state.Pushing[info.Id] = true
    state.Logger.print(
        `[AutoPush] Publishing "{info.Name or info.Id}" from {info.Root:GetFullName()} ({childCount} children)...`
    )

    local result = state.PackagePublisher.publish(state.Bloxdrive.Serializer, {
        PackageId = info.Id,
        PackageName = info.Name or info.Id,
        Root = info.Root,
        RegistryKey = key,
    })

    if not _isCurrentGeneration() then
        state.Pushing[info.Id] = nil
        return
    end

    if result.Success then
        -- Update marker while Pushing is still true so the
        -- lockdown's value-change listener ignores this update
        local decoded = HttpService:JSONDecode(info.Marker.Value)
        decoded.Version = result.Version
        info.Marker.Value = HttpService:JSONEncode(decoded)
        info.Version = result.Version

        state.Pushing[info.Id] = nil

        ChangeHistoryService:SetWaypoint(`AutoPush {info.Name or info.Id} version {result.Version}`)
        state.Logger.print(`[AutoPush] Published "{info.Name or info.Id}" version {result.Version}.`)
    else
        state.Pushing[info.Id] = nil
        state.Logger.warn(`[AutoPush] Failed to publish "{info.Id}": {result.Error}`)
    end

    _drainPendingOperations(info.Id)
end

function _startPolling()
    local state = _state :: AutoSyncState

    state.PollThread = task.spawn(function()
        while state.Running and _isCurrentGeneration() do
            task.wait(PULL_POLL_SECONDS)

            if not state.Running or not _isCurrentGeneration() then
                break
            end

            -- Pull all registered packages with AutoPull enabled
            for _, info in state.RegisteredPackages do
                if info.AutoPull then
                    _autoPull(info)
                end
            end
        end
    end)
end

return AutoSync
