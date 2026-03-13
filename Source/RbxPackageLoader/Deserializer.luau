--[[

Deserializer

Converts a TreeNode structure back into Roblox instances. Creates instances
using `Instance.new()`, sets properties and attributes, then recurses for
children.

Also provides `reassembleTree` which reconstructs a monolithic TreeNode
from the registry's hierarchical file map (path -> content pairs).

--]]

local PropertyReflection = require("@self/PropertyReflection")
local TreeUtils = require("@self/TreeUtils")

local Deserializer = {}

--[=[
    Deserializes a TreeNode into a Roblox instance subtree and parents it
    under the given parent instance.

    @param name string -- The name for the root instance
    @param tree TreeNode -- The serialized tree to hydrate
    @param parent Instance -- The parent to place the root instance under
    @return Instance -- The created root instance
]=]
function Deserializer.deserialize(name: string, tree: { [string]: any }, parent: Instance): Instance
    assert(type(name) == "string", "Expected a string name")
    assert(type(tree) == "table", "Expected a table tree")
    assert(typeof(parent) == "Instance", "Expected an Instance parent")

    return _deserializeNode(name, tree, parent)
end

function _deserializeNode(name: string, node: { [string]: any }, parent: Instance): Instance
    local className = node["$className"]
    assert(type(className) == "string", `Expected $className for "{name}"`)

    local instance = Instance.new(className)

    -- Set properties before parenting for efficiency
    local properties = node["$properties"]
    if properties then
        for propName, propValue in properties do
            PropertyReflection.setProperty(instance, propName, propValue)
        end
    end

    -- Set attributes
    local attributes = node["$attributes"]
    if attributes then
        for attrName, attrValue in attributes do
            instance:SetAttribute(attrName, attrValue)
        end
    end

    -- Recurse for children (non-$ keys)
    for key, childNode in node do
        if TreeUtils.isMetadataKey(key) then
            continue
        end

        if type(childNode) ~= "table" or childNode["$className"] == nil then
            continue
        end

        _deserializeNode(key, childNode, instance)
    end

    -- Set name and parent last
    instance.Name = name
    instance.Parent = parent

    return instance
end

--[=[
    Reconstructs a monolithic TreeNode from a flat map of file paths to
    their JSON-decoded content. This is the inverse of
    `Serializer.serializeToFiles`.

    @param files { [string]: any } -- Map of relative paths to content
    @return TreeNode -- The reassembled tree
]=]
function Deserializer.reassembleTree(files: { [string]: any }): { [string]: any }
    assert(type(files) == "table", "Expected a table of files")
    assert(files["instance.json"] ~= nil, "Missing root instance.json")

    return _reassembleAtPrefix(files, "")
end

function _reassembleAtPrefix(files: { [string]: any }, prefix: string): { [string]: any }
    -- Get this node's metadata from instance.json
    local instancePath = if prefix == "" then "instance.json" else `{prefix}/instance.json`
    local node = {}

    local metadata = files[instancePath]
    assert(metadata ~= nil, `Missing metadata at "{instancePath}"`)

    for key, value in metadata do
        node[key] = value
    end

    -- Find all direct children at this prefix level
    local childrenFound: { [string]: string } = {}

    for path in files do
        if path == instancePath then
            continue
        end

        -- Check if this path belongs under our prefix
        local relativePath: string
        if prefix == "" then
            relativePath = path
        elseif string.sub(path, 1, #prefix + 1) == `{prefix}/` then
            relativePath = string.sub(path, #prefix + 2)
        else
            continue
        end

        -- Extract the top-level segment of the relative path
        local slashPos = string.find(relativePath, "/")
        if slashPos then
            -- This is inside a subdirectory (container child)
            local dirName = string.sub(relativePath, 1, slashPos - 1)
            if not childrenFound[dirName] then
                childrenFound[dirName] = "directory"
            end
        else
            -- This is a direct file (leaf child)
            -- Strip the .json extension to get the child name
            if string.sub(relativePath, -5) == ".json" then
                local childName = string.sub(relativePath, 1, -6)
                childrenFound[childName] = "file"
            end
        end
    end

    -- Reassemble each child
    for childName, childType in childrenFound do
        if childType == "directory" then
            local childPrefix = if prefix == "" then childName else `{prefix}/{childName}`
            node[childName] = _reassembleAtPrefix(files, childPrefix)
        else
            local filePath = if prefix == "" then `{childName}.json` else `{prefix}/{childName}.json`
            local childData = files[filePath]
            if childData then
                node[childName] = childData
            end
        end
    end

    return node
end

return Deserializer
