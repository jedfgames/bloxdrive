--[[

Serializer

Converts a Roblox instance subtree into a TreeNode structure using Rojo's
project format conventions. Each instance becomes a node with `$className`,
`$properties`, `$attributes`, and children keyed by name.

Also provides `serializeToFiles` which splits a TreeNode into a
hierarchical file map suitable for the registry's per-file storage
format. Leaf instances become `Name.json` files, containers become
directories with `instance.json`.

--]]

local PropertyReflection = require("./PropertyReflection")
local TreeUtils = require("./TreeUtils")

local PACKAGE_MARKER_NAME = ".rbx-package"

local Serializer = {}

--[=[
    Serializes an instance and all its descendants into a TreeNode. Skips
    the `.rbx-package` StringValue marker since it is metadata, not package
    content.

    @param root Instance -- The root instance to serialize
    @return TreeNode -- The serialized tree
]=]
function Serializer.serialize(root: Instance): { [string]: any }
    assert(typeof(root) == "Instance", "Expected an Instance")
    return _serializeInstance(root)
end

function _serializeInstance(instance: Instance): { [string]: any }
    local node: { [string]: any } = {}

    node["$className"] = instance.ClassName

    -- Serialize properties
    local properties = PropertyReflection.getSerializableProperties(instance)
    if next(properties) ~= nil then
        node["$properties"] = properties
    end

    -- Serialize attributes
    local attributes = instance:GetAttributes()
    if next(attributes) ~= nil then
        node["$attributes"] = attributes
    end

    -- Serialize children, skipping the package marker. When
    -- multiple children share the same name, auto-increment like
    -- Roblox does (Part, Part1, Part2). The instance is also
    -- renamed in the DataModel to keep things consistent.
    local usedKeys: { [string]: boolean } = {}

    for _, child in instance:GetChildren() do
        if child.Name == PACKAGE_MARKER_NAME and child:IsA("StringValue") then
            continue
        end

        local childName = child.Name
        if TreeUtils.isMetadataKey(childName) then
            childName = `_{childName}`
        end

        if usedKeys[childName] then
            local counter = 1
            while usedKeys[`{childName}{counter}`] do
                counter += 1
            end
            childName = `{childName}{counter}`
            child.Name = childName
        end

        usedKeys[childName] = true
        node[childName] = _serializeInstance(child)
    end

    return node
end

--[=[
    Splits a TreeNode into a flat map of file paths to their JSON-encodable
    content, matching the registry's hierarchical storage format. Also
    returns a manifest listing all file paths.

    Leaf nodes (no children) become `Name.json`. Container nodes (have
    children) become directories with `instance.json` for their own
    metadata.

    @param tree TreeNode -- The tree to split into files
    @return { Files: { [string]: any }, Manifest: { string } }
]=]
function Serializer.serializeToFiles(tree: { [string]: any }): { Files: { [string]: any }, Manifest: { string } }
    assert(type(tree) == "table", "Expected a table tree")

    local files: { [string]: any } = {}
    local manifest: { string } = {}

    _serializeNodeToFiles(tree, "", files, manifest)

    return {
        Files = files,
        Manifest = manifest,
    }
end

function _extractMetadata(node: { [string]: any }): { [string]: any }
    local metadata: { [string]: any } = {}
    metadata["$className"] = node["$className"]

    if node["$properties"] then
        metadata["$properties"] = node["$properties"]
    end

    if node["$attributes"] then
        metadata["$attributes"] = node["$attributes"]
    end

    return metadata
end

function _serializeNodeToFiles(node: { [string]: any }, prefix: string, files: { [string]: any }, manifest: { string })
    local children = TreeUtils.getChildKeys(node)
    local hasChildren = next(children) ~= nil

    if prefix == "" then
        -- Root node always gets instance.json
        local path = "instance.json"
        files[path] = _extractMetadata(node)
        table.insert(manifest, path)
    elseif hasChildren then
        -- Container: directory with instance.json
        local path = `{prefix}/instance.json`
        files[path] = _extractMetadata(node)
        table.insert(manifest, path)
    else
        -- Leaf: single .json file (prefix already includes .json from caller)
        files[prefix] = _extractMetadata(node)
        table.insert(manifest, prefix)
        return
    end

    -- Recurse into children
    for childName in children do
        local childNode = node[childName]
        local childChildren = TreeUtils.getChildKeys(childNode)
        local childHasChildren = next(childChildren) ~= nil

        if childHasChildren then
            local childPrefix = if prefix == "" then childName else `{prefix}/{childName}`
            _serializeNodeToFiles(childNode, childPrefix, files, manifest)
        else
            local childPath = if prefix == "" then `{childName}.json` else `{prefix}/{childName}.json`
            _serializeNodeToFiles(childNode, childPath, files, manifest)
        end
    end
end

return Serializer
