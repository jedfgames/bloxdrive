--[[

PackagePuller

Handles pulling and updating packages from the registry into the DataModel.
Fetches the target version from the registry, performs a three-way merge if
the package already exists locally, and applies the result.

--]]

local HttpService = game:GetService("HttpService")

local Logger = require(script.Parent.Parent.RbxPackageLoader.Logger)

local PACKAGE_MARKER_NAME = ".rbx-package"

local PackagePuller = {}

type PullOptions = {
    PackageId: string,
    PackageName: string?,
    Parent: Instance,
    Version: number?,
    AuthToken: string?,
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

    @param loader RbxPackageLoader -- The loader module (for sub-modules)
    @param options PullOptions -- Pull configuration
    @return PullResult -- The result of the pull operation
]=]
function PackagePuller.pull(loader: any, options: PullOptions): PullResult
    assert(type(options.PackageId) == "string", "Expected a string PackageId")
    assert(typeof(options.Parent) == "Instance", "Expected an Instance Parent")

    local success, result = pcall(function(): PullResult
        local registryConfig = nil
        if options.AuthToken then
            registryConfig = { AuthToken = options.AuthToken }
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

            -- Clear and reapply
            _clearContent(options.Parent)
            _applyChildren(loader, mergeResult.Tree, options.Parent)

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
