--[[

Types

Type definitions for the rbx-package-loader system. Defines the shapes of
serialized instance trees, package markers, registry metadata, diff
operations, and merge results.

--]]

local Types = {}

--[=[
    Parsed contents of a `.rbx-package` StringValue. Identifies which package
    a subtree belongs to, what version is installed, and whether to
    auto-update.
]=]
export type PackageMarker = {
    Id: string,
    Version: number,
    AutoUpdate: boolean,
}

--[=[
    A serialized instance tree node using Rojo's project format conventions.
    `$className` is the Roblox class, `$properties` holds property values
    (implicit or explicit Rojo format), `$attributes` holds instance
    attributes, and all other string keys are child nodes keyed by name.
]=]
export type TreeNode = {
    ["$className"]: string,
    ["$properties"]: { [string]: any }?,
    ["$attributes"]: { [string]: any }?,
    [string]: TreeNode,
}

--[=[
    Registry metadata for a package, stored as `metadata.json` in the
    registry repo.
]=]
export type PackageMetadata = {
    Name: string,
    LatestVersion: number,
}

--[=[
    Configuration for connecting to the package registry.
]=]
export type RegistryConfig = {
    BaseUrl: string,
    AuthToken: string?,
}

--[=[
    A single diff operation produced by TreeDiff. `Kind` describes the change
    type, `Path` is the list of ancestor names leading to the affected node.
]=]
export type DiffOperation = {
    Kind: "Add" | "Remove" | "Modify",
    Path: { string },
    OldValue: any?,
    NewValue: any?,
    Node: TreeNode?,
}

--[=[
    Information about a single merge conflict.
]=]
export type ConflictInfo = {
    Path: { string },
    LocalValue: any,
    RemoteValue: any,
}

--[=[
    The result of a three-way merge operation.
]=]
export type MergeResult = {
    Tree: TreeNode,
    Conflicts: { ConflictInfo },
}

--[=[
    Options passed to the `load` function.
]=]
export type LoadOptions = {
    Version: number?,
    Parent: Instance?,
}

--[=[
    The result of loading a package.
]=]
export type LoadResult = {
    PackageId: string,
    Success: boolean,
    Version: number,
    Conflicts: { ConflictInfo }?,
    Error: string?,
}

--[=[
    Information about a discovered package marker in the DataModel.
]=]
export type PackageInfo = {
    Marker: StringValue,
    Parent: Instance,
    Metadata: PackageMarker,
}

return Types
