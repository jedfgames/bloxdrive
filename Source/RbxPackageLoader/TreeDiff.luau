--[[

TreeDiff

Computes the structural and property differences between two TreeNodes.
Produces a list of diff operations (Add, Remove, Modify) that describe how
to transform the old tree into the new tree. Children are matched by name
since they are keyed by name in the Rojo format.

--]]

local TreeUtils = require("@self/TreeUtils")

local TreeDiff = {}

type DiffOperation = {
    Kind: "Add" | "Remove" | "Modify",
    Path: { string },
    OldValue: any?,
    NewValue: any?,
    Node: { [string]: any }?,
}

--[=[
    Computes the diff between two TreeNodes. Returns a list of operations
    that describe how to transform `oldTree` into `newTree`.

    @param oldTree TreeNode -- The original tree
    @param newTree TreeNode -- The updated tree
    @return { DiffOperation } -- The list of diff operations
]=]
function TreeDiff.diff(oldTree: { [string]: any }, newTree: { [string]: any }): { DiffOperation }
    assert(type(oldTree) == "table", "Expected a table for oldTree")
    assert(type(newTree) == "table", "Expected a table for newTree")

    local operations: { DiffOperation } = {}
    _diffNodes(oldTree, newTree, {}, operations)
    return operations
end

function _diffNodes(
    oldNode: { [string]: any },
    newNode: { [string]: any },
    path: { string },
    operations: { DiffOperation }
)
    -- Diff properties
    _diffProperties(oldNode["$properties"] or {}, newNode["$properties"] or {}, path, operations)

    -- Diff attributes
    _diffAttributes(oldNode["$attributes"] or {}, newNode["$attributes"] or {}, path, operations)

    -- Diff children
    local oldChildren = TreeUtils.getChildKeys(oldNode)
    local newChildren = TreeUtils.getChildKeys(newNode)

    -- Find removed children
    for childName in oldChildren do
        if newChildren[childName] == nil then
            local childPath = table.clone(path)
            table.insert(childPath, childName)
            table.insert(operations, {
                Kind = "Remove",
                Path = childPath,
                OldValue = oldNode[childName],
            })
        end
    end

    -- Find added children
    for childName in newChildren do
        if oldChildren[childName] == nil then
            local childPath = table.clone(path)
            table.insert(childPath, childName)
            table.insert(operations, {
                Kind = "Add",
                Path = childPath,
                Node = newNode[childName],
            })
        end
    end

    -- Recurse into shared children
    for childName in oldChildren do
        if newChildren[childName] then
            local childPath = table.clone(path)
            table.insert(childPath, childName)

            -- Check if className changed (effectively a replacement)
            if oldNode[childName]["$className"] ~= newNode[childName]["$className"] then
                table.insert(operations, {
                    Kind = "Remove",
                    Path = childPath,
                    OldValue = oldNode[childName],
                })
                table.insert(operations, {
                    Kind = "Add",
                    Path = childPath,
                    Node = newNode[childName],
                })
            else
                _diffNodes(oldNode[childName], newNode[childName], childPath, operations)
            end
        end
    end
end

function _diffProperties(
    oldProps: { [string]: any },
    newProps: { [string]: any },
    path: { string },
    operations: { DiffOperation }
)
    local propPath = table.clone(path)
    table.insert(propPath, "$properties")

    -- Find removed or modified properties
    for propName, oldValue in oldProps do
        local newValue = newProps[propName]
        if newValue == nil then
            local fullPath = table.clone(propPath)
            table.insert(fullPath, propName)
            table.insert(operations, {
                Kind = "Remove",
                Path = fullPath,
                OldValue = oldValue,
            })
        elseif not TreeUtils.deepEqual(oldValue, newValue) then
            local fullPath = table.clone(propPath)
            table.insert(fullPath, propName)
            table.insert(operations, {
                Kind = "Modify",
                Path = fullPath,
                OldValue = oldValue,
                NewValue = newValue,
            })
        end
    end

    -- Find added properties
    for propName, newValue in newProps do
        if oldProps[propName] == nil then
            local fullPath = table.clone(propPath)
            table.insert(fullPath, propName)
            table.insert(operations, {
                Kind = "Add",
                Path = fullPath,
                NewValue = newValue,
            })
        end
    end
end

function _diffAttributes(
    oldAttrs: { [string]: any },
    newAttrs: { [string]: any },
    path: { string },
    operations: { DiffOperation }
)
    local attrPath = table.clone(path)
    table.insert(attrPath, "$attributes")

    -- Find removed or modified attributes
    for attrName, oldValue in oldAttrs do
        local newValue = newAttrs[attrName]
        if newValue == nil then
            local fullPath = table.clone(attrPath)
            table.insert(fullPath, attrName)
            table.insert(operations, {
                Kind = "Remove",
                Path = fullPath,
                OldValue = oldValue,
            })
        elseif not TreeUtils.deepEqual(oldValue, newValue) then
            local fullPath = table.clone(attrPath)
            table.insert(fullPath, attrName)
            table.insert(operations, {
                Kind = "Modify",
                Path = fullPath,
                OldValue = oldValue,
                NewValue = newValue,
            })
        end
    end

    -- Find added attributes
    for attrName, newValue in newAttrs do
        if oldAttrs[attrName] == nil then
            local fullPath = table.clone(attrPath)
            table.insert(fullPath, attrName)
            table.insert(operations, {
                Kind = "Add",
                Path = fullPath,
                NewValue = newValue,
            })
        end
    end
end

return TreeDiff
