--[[

RbxPackageLoader

A toolchain for managing Roblox instance-based packages deterministically.
Replaces Roblox's native package system with one that supports
programmatic control, optimistic merging, and conflict resolution.

The primary public API is `load`, which fetches a package by ID and
optional version number from the registry and deserializes it into the
DataModel.

--]]

local Deserializer = require("@self/Deserializer")
local Logger = require("@self/Logger")
local Merger = require("@self/Merger")
local PackageScanner = require("@self/PackageScanner")
local PropertyReflection = require("@self/PropertyReflection")
local Registry = require("@self/Registry")
local Serializer = require("@self/Serializer")
local TreeDiff = require("@self/TreeDiff")
local TreeUtils = require("@self/TreeUtils")
local Types = require("@self/Types")

local HttpService = game:GetService("HttpService")

local PACKAGE_MARKER_NAME = ".rbx-package"

local RbxPackageLoader = {}

-- Re-export sub-modules for plugin and advanced usage
RbxPackageLoader.Deserializer = Deserializer
RbxPackageLoader.Merger = Merger
RbxPackageLoader.PackageScanner = PackageScanner
RbxPackageLoader.PropertyReflection = PropertyReflection
RbxPackageLoader.Registry = Registry
RbxPackageLoader.Serializer = Serializer
RbxPackageLoader.TreeDiff = TreeDiff
RbxPackageLoader.TreeUtils = TreeUtils
RbxPackageLoader.Types = Types

type LoadOptions = {
    Version: number?,
    Parent: Instance,
}

type LoadResult = {
    PackageId: string,
    Success: boolean,
    Version: number,
    Conflicts: { Types.ConflictInfo }?,
    Error: string?,
}

--[=[
    Loads a package by ID from the registry and places it under the given
    parent instance. If a version is not specified, the latest version is
    fetched.

    If the parent already contains package content (identified by a
    `.rbx-package` marker), a three-way merge is performed between the
    previously installed version, the current DataModel state, and the new
    version.

    @param packageId string -- The package identifier
    @param options LoadOptions -- Load options including parent and version
    @return LoadResult -- The result of the load operation
]=]
function RbxPackageLoader.load(packageId: string, options: LoadOptions): LoadResult
    assert(type(packageId) == "string", "Expected a string packageId")
    assert(type(options) == "table", "Expected a table options")
    assert(typeof(options.Parent) == "Instance", "Expected an Instance for options.Parent")

    local success, result = pcall(function(): LoadResult
        local registry = Registry.new()

        -- Determine which version to fetch
        local targetVersion: number
        local remoteTree: { [string]: any }

        if options.Version then
            targetVersion = options.Version
            remoteTree = registry:FetchVersion(packageId, targetVersion)
        else
            remoteTree, targetVersion = registry:FetchLatest(packageId)
        end

        -- Check for existing package marker
        local existingMarker = _findExistingMarker(options.Parent, packageId)

        if existingMarker then
            -- Package already exists, perform a merge
            local currentVersion = existingMarker.Metadata.Version

            if currentVersion == targetVersion then
                return {
                    PackageId = packageId,
                    Success = true,
                    Version = targetVersion,
                }
            end

            -- Fetch the base version (what was originally installed)
            local baseTree = registry:FetchVersion(packageId, currentVersion)

            -- Serialize the current DataModel state as the local version
            local localTree = Serializer.serialize(existingMarker.Parent)

            -- Three-way merge
            local mergeResult = Merger.merge(baseTree, localTree, remoteTree)

            -- Clear existing children (except the marker)
            _clearPackageContent(existingMarker.Parent)

            -- Deserialize the merged tree
            _applyTree(mergeResult.Tree, existingMarker.Parent)

            -- Update the marker
            _updateMarker(existingMarker.Marker, packageId, targetVersion)

            local conflicts = if #mergeResult.Conflicts > 0 then mergeResult.Conflicts else nil

            if conflicts then
                for _, conflict in conflicts do
                    Logger.warn(`Conflict in "{packageId}" at {table.concat(conflict.Path, ".")}`)
                end
            end

            return {
                PackageId = packageId,
                Success = true,
                Version = targetVersion,
                Conflicts = conflicts,
            }
        else
            -- Fresh install
            _applyTree(remoteTree, options.Parent)

            -- Create the package marker
            _createMarker(options.Parent, packageId, targetVersion)

            return {
                PackageId = packageId,
                Success = true,
                Version = targetVersion,
            }
        end
    end)

    if not success then
        return {
            PackageId = packageId,
            Success = false,
            Version = 0,
            Error = tostring(result),
        }
    end

    return result
end

function _findExistingMarker(parent: Instance, packageId: string): Types.PackageInfo?
    for _, child in parent:GetChildren() do
        if child:IsA("StringValue") and child.Name == PACKAGE_MARKER_NAME then
            local decodeSuccess, metadata = pcall(function()
                local decoded = HttpService:JSONDecode(child.Value)
                return {
                    Id = decoded.Id,
                    Version = decoded.Version,
                    AutoUpdate = decoded.AutoUpdate or false,
                }
            end)

            if decodeSuccess and metadata.Id == packageId then
                return {
                    Marker = child :: StringValue,
                    Parent = parent,
                    Metadata = metadata,
                }
            end
        end
    end

    return nil
end

function _clearPackageContent(parent: Instance)
    for _, child in parent:GetChildren() do
        if child.Name ~= PACKAGE_MARKER_NAME then
            child:Destroy()
        end
    end
end

function _applyTree(tree: { [string]: any }, parent: Instance)
    -- The tree root represents the parent itself, so we apply its children
    for key, value in tree do
        if TreeUtils.isMetadataKey(key) then
            continue
        end

        if type(value) ~= "table" or value["$className"] == nil then
            continue
        end

        Deserializer.deserialize(key, value, parent)
    end

    -- Apply root-level properties to the parent
    local properties = tree["$properties"]
    if properties then
        for propName, propValue in properties do
            PropertyReflection.setProperty(parent, propName, propValue)
        end
    end

    -- Apply root-level attributes to the parent
    local attributes = tree["$attributes"]
    if attributes then
        for attrName, attrValue in attributes do
            parent:SetAttribute(attrName, attrValue)
        end
    end
end

function _createMarker(parent: Instance, packageId: string, version: number)
    local marker = Instance.new("StringValue")
    marker.Name = PACKAGE_MARKER_NAME
    marker.Value = HttpService:JSONEncode({
        Id = packageId,
        Version = version,
        AutoUpdate = false,
    })
    marker.Parent = parent
end

function _updateMarker(marker: StringValue, packageId: string, version: number)
    local decoded = HttpService:JSONDecode(marker.Value)
    decoded.Version = version
    marker.Value = HttpService:JSONEncode(decoded)
end

return RbxPackageLoader
