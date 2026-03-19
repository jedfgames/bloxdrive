--[[

PackagePuller

Handles pulling and updating packages from the registry into the DataModel.
Fetches the target version from the registry, performs a three-way merge if
the package already exists locally, and applies the result.

--]]

local HttpService = game:GetService("HttpService")

local Logger = require("@bloxdrive/Logger")

local PACKAGE_MARKER_NAME = ".bloxdrive"

local PackagePuller = {}

type PullOptions = {
    PackageId: string,
    PackageName: string?,
    Parent: Instance,
    Version: number?,
    RegistryKey: string?,
}

type PullResult = {
    Success: boolean,
    Version: number?,
    ConflictCount: number,
    Error: string?,
}

--[=[
    Pulls a package from the registry and applies it to the given parent
    instance. If the package already exists locally with modifications,
    performs a three-way merge.

    @param loader Bloxdrive -- The loader module (for sub-modules)
    @param options PullOptions -- Pull configuration
    @return PullResult -- The result of the pull operation
]=]
function PackagePuller.pull(loader: any, options: PullOptions): PullResult
    assert(type(options.PackageId) == "string", "Expected a string PackageId")
    assert(typeof(options.Parent) == "Instance", "Expected an Instance Parent")

    local success, result = pcall(function(): PullResult
        local registryConfig = nil
        if options.RegistryKey then
            registryConfig = { RegistryKey = options.RegistryKey }
        end

        local registry = loader.Registry.new(registryConfig)

        -- Determine which version to fetch
        local targetVersion: number
        local remoteTree: { [string]: any }

        if options.Version then
            targetVersion = options.Version
            remoteTree = registry:FetchVersion(options.PackageId, targetVersion)
        else
            remoteTree, targetVersion = registry:FetchLatest(options.PackageId)
        end

        -- Check for existing package marker
        local existingMarker = _findMarker(options.Parent, options.PackageId)

        if existingMarker and existingMarker.Version > 0 then
            local currentVersion = existingMarker.Version

            if currentVersion == targetVersion then
                return {
                    Success = true,
                    Version = targetVersion,
                    ConflictCount = 0,
                }
            end

            -- Fetch the base version
            local baseTree = registry:FetchVersion(options.PackageId, currentVersion)

            -- Serialize current state
            local localTree = loader.Serializer.serialize(options.Parent)

            -- Three-way merge
            local mergeResult = loader.Merger.merge(baseTree, localTree, remoteTree)

            -- Surgically apply only the changes needed
            _applyTreeSurgically(loader, mergeResult.Tree, options.Parent)

            -- Update marker
            _updateMarker(existingMarker.Marker, targetVersion)

            -- Log conflicts
            local conflictCount = #mergeResult.Conflicts
            if conflictCount > 0 then
                for _, conflict in mergeResult.Conflicts do
                    Logger.warn(`Conflict in "{options.PackageId}" at {table.concat(conflict.Path, ".")}`)
                end
            end

            return {
                Success = true,
                Version = targetVersion,
                ConflictCount = conflictCount,
            }
        else
            -- Fresh install (no marker or version 0)
            _clearContent(options.Parent)
            _applyChildren(loader, remoteTree, options.Parent)

            if existingMarker then
                _updateMarker(existingMarker.Marker, targetVersion)
            else
                _createMarker(options.Parent, options.PackageId, options.PackageName, targetVersion)
            end

            return {
                Success = true,
                Version = targetVersion,
                ConflictCount = 0,
            }
        end
    end)

    if not success then
        return {
            Success = false,
            ConflictCount = 0,
            Error = tostring(result),
        }
    end

    return result
end

function _findMarker(parent: Instance, packageId: string): { Marker: StringValue, Version: number }?
    for _, child in parent:GetChildren() do
        if child:IsA("StringValue") and child.Name == PACKAGE_MARKER_NAME then
            local decodeSuccess, decoded = pcall(function()
                return HttpService:JSONDecode(child.Value)
            end)

            if decodeSuccess and decoded.Id == packageId then
                return {
                    Marker = child :: StringValue,
                    Version = decoded.Version,
                }
            end
        end
    end

    return nil
end

function _clearContent(parent: Instance)
    for _, child in parent:GetChildren() do
        if child.Name ~= PACKAGE_MARKER_NAME then
            child:Destroy()
        end
    end
end

function _applyChildren(loader: any, tree: { [string]: any }, parent: Instance)
    local TreeUtils = loader.TreeUtils

    for key, value in tree do
        if TreeUtils.isMetadataKey(key) then
            continue
        end

        if type(value) ~= "table" or value["$className"] == nil then
            continue
        end

        loader.Deserializer.deserialize(key, value, parent)
    end

    -- Apply root-level properties
    local properties = tree["$properties"]
    if properties then
        for propName, propValue in properties do
            loader.PropertyReflection.setProperty(parent, propName, propValue)
        end
    end

    -- Apply root-level attributes
    local attributes = tree["$attributes"]
    if attributes then
        for attrName, attrValue in attributes do
            parent:SetAttribute(attrName, attrValue)
        end
    end
end

-- Resolves an instance by walking a path of child names from a
-- root instance. Returns nil if any segment is not found.
function _resolveInstance(root: Instance, path: { string }, depth: number): Instance?
    local current = root
    for i = 1, depth do
        local child = current:FindFirstChild(path[i])
        if not child then
            return nil
        end
        current = child
    end
    return current
end

-- Finds the index of "$properties" or "$attributes" in a path.
-- Returns nil if neither is found.
function _findMetadataIndex(path: { string }): number?
    for i, segment in path do
        if segment == "$properties" or segment == "$attributes" then
            return i
        end
    end
    return nil
end

-- Applies a target tree to an instance surgically, only creating,
-- deleting, or modifying what differs from the current state.
-- This preserves instance identity and avoids unnecessary churn.
function _applyTreeSurgically(loader: any, targetTree: { [string]: any }, parent: Instance)
    local currentTree = loader.Serializer.serialize(parent)
    local operations = loader.TreeDiff.diff(currentTree, targetTree)

    -- Sort operations: removes first (deepest first), then adds
    -- (shallowest first), then modifies
    local removes = {}
    local adds = {}
    local modifies = {}

    for _, op in operations do
        if op.Kind == "Remove" then
            table.insert(removes, op)
        elseif op.Kind == "Add" then
            table.insert(adds, op)
        else
            table.insert(modifies, op)
        end
    end

    -- Sort removes deepest-first so children are destroyed before
    -- parents
    table.sort(removes, function(a, b)
        return #a.Path > #b.Path
    end)

    -- Sort adds shallowest-first so parents exist before children
    table.sort(adds, function(a, b)
        return #a.Path < #b.Path
    end)

    -- Apply removes
    for _, op in removes do
        _applyOperation(loader, op, parent)
    end

    -- Apply adds
    for _, op in adds do
        _applyOperation(loader, op, parent)
    end

    -- Apply modifies
    for _, op in modifies do
        _applyOperation(loader, op, parent)
    end
end

function _applyOperation(loader: any, op: any, root: Instance)
    local path = op.Path
    local metaIndex = _findMetadataIndex(path)

    if metaIndex then
        -- Property or attribute operation
        local instanceDepth = metaIndex - 1
        local target = if instanceDepth > 0 then _resolveInstance(root, path, instanceDepth) else root

        if not target then
            Logger.warn(`[PackagePuller] Could not resolve instance for path "{table.concat(path, ".")}".`)
            return
        end

        local metaType = path[metaIndex]
        local key = path[metaIndex + 1]

        if not key then
            return
        end

        if metaType == "$properties" then
            if op.Kind == "Remove" then
                -- Reset to default by creating a temp instance
                local className = target.ClassName
                local tempSuccess, temp = pcall(Instance.new, className)
                if tempSuccess then
                    local defaultSuccess, defaultValue = pcall(function()
                        return (temp :: any)[key]
                    end)
                    if defaultSuccess then
                        pcall(function()
                            (target :: any)[key] = defaultValue
                        end)
                    end
                    temp:Destroy()
                end
            else
                loader.PropertyReflection.setProperty(target, key, op.NewValue)
            end
        elseif metaType == "$attributes" then
            if op.Kind == "Remove" then
                target:SetAttribute(key, nil)
            else
                local decoded = loader.PropertyReflection.decodeValue(op.NewValue)
                target:SetAttribute(key, decoded)
            end
        end
    else
        -- Child instance operation
        local instanceDepth = #path - 1
        local childName = path[#path]
        local parentInstance = if instanceDepth > 0 then _resolveInstance(root, path, instanceDepth) else root

        if not parentInstance then
            Logger.warn(`[PackagePuller] Could not resolve parent for path "{table.concat(path, ".")}".`)
            return
        end

        if op.Kind == "Remove" then
            local child = parentInstance:FindFirstChild(childName)
            if child then
                child:Destroy()
            end
        elseif op.Kind == "Add" then
            loader.Deserializer.deserialize(childName, op.Node, parentInstance)
        end
    end
end

function _createMarker(parent: Instance, packageId: string, packageName: string?, version: number)
    local marker = Instance.new("StringValue")
    marker.Name = PACKAGE_MARKER_NAME
    marker.Value = HttpService:JSONEncode({
        AutoPull = true,
        AutoPush = true,
        Id = packageId,
        Name = packageName or packageId,
        Version = version,
    })
    marker.Parent = parent
end

function _updateMarker(marker: StringValue, version: number)
    local decoded = HttpService:JSONDecode(marker.Value)
    decoded.Version = version
    marker.Value = HttpService:JSONEncode(decoded)
end

return PackagePuller
