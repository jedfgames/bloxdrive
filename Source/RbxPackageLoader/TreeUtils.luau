--[[

TreeUtils

Pure utility functions for working with TreeNode tables. Has no Roblox API
dependencies so it can be used in both Studio and Lune contexts.

--]]

local METADATA_KEYS = {
    ["$className"] = true,
    ["$properties"] = true,
    ["$attributes"] = true,
}

local TreeUtils = {}

--[=[
    Returns whether a key is a metadata key (prefixed with `$`) rather than
    a child instance name.

    @param key string -- The key to check
    @return boolean -- Whether the key is a metadata key
]=]
function TreeUtils.isMetadataKey(key: string): boolean
    return METADATA_KEYS[key] == true
end

--[=[
    Returns all child keys from a TreeNode (non-metadata keys that are
    tables with a `$className` field).

    @param node TreeNode -- The node to get children from
    @return { [string]: boolean } -- Set of child names
]=]
function TreeUtils.getChildKeys(node: { [string]: any }): { [string]: boolean }
    local children = {}
    for key, value in node do
        if not METADATA_KEYS[key] and type(value) == "table" and value["$className"] ~= nil then
            children[key] = true
        end
    end
    return children
end

--[=[
    Deep equality comparison for arbitrary values, including nested tables.

    @param a any -- First value
    @param b any -- Second value
    @return boolean -- Whether the values are deeply equal
]=]
function TreeUtils.deepEqual(a: any, b: any): boolean
    if type(a) ~= type(b) then
        return false
    end

    if type(a) ~= "table" then
        return a == b
    end

    for key, valueA in a do
        if not TreeUtils.deepEqual(valueA, b[key]) then
            return false
        end
    end

    for key in b do
        if a[key] == nil then
            return false
        end
    end

    return true
end

--[=[
    Deep clones a value, recursively cloning tables.

    @param value any -- The value to clone
    @return any -- The cloned value
]=]
function TreeUtils.deepClone(value: any): any
    if type(value) ~= "table" then
        return value
    end

    local clone = {}
    for key, v in value do
        clone[key] = TreeUtils.deepClone(v)
    end
    return clone
end

return TreeUtils
