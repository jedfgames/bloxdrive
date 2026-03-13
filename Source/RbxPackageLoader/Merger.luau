--[[

Merger

Performs three-way merging of TreeNodes. Given a base version, a local
version, and a remote version, produces a merged tree with optimistic
conflict resolution. Non-overlapping changes merge cleanly. Conflicts
produce `_CONFLICT` suffixed duplicates and `_ORPHANED` containers,
following the Google Docs philosophy of never blocking the user.

--]]

local TreeDiff = require("@self/TreeDiff")
local TreeUtils = require("@self/TreeUtils")

local Merger = {}

type ConflictInfo = {
    Path: { string },
    LocalValue: any,
    RemoteValue: any,
}

type MergeResult = {
    Tree: { [string]: any },
    Conflicts: { ConflictInfo },
}

--[=[
    Performs a three-way merge between a base tree, a local tree, and a
    remote tree. Changes from both local and remote are applied
    optimistically. When both sides modify the same property to different
    values, a conflict is recorded and both versions are preserved.

    @param baseTree TreeNode -- The common ancestor version
    @param localTree TreeNode -- The locally modified version
    @param remoteTree TreeNode -- The remotely modified version
    @return MergeResult -- The merged tree and any conflicts
]=]
function Merger.merge(
    baseTree: { [string]: any },
    localTree: { [string]: any },
    remoteTree: { [string]: any }
): MergeResult
    assert(type(baseTree) == "table", "Expected a table for baseTree")
    assert(type(localTree) == "table", "Expected a table for localTree")
    assert(type(remoteTree) == "table", "Expected a table for remoteTree")

    local conflicts: { ConflictInfo } = {}
    local merged = _mergeNodes(baseTree, localTree, remoteTree, {}, conflicts)

    return {
        Tree = merged,
        Conflicts = conflicts,
    }
end

function _mergeNodes(
    baseNode: { [string]: any },
    localNode: { [string]: any },
    remoteNode: { [string]: any },
    path: { string },
    conflicts: { ConflictInfo }
): { [string]: any }
    local merged: { [string]: any } = {}

    -- Use local's className as the base (should be same across all three)
    merged["$className"] = localNode["$className"]

    -- Merge properties
    merged["$properties"] = _mergeTable(
        baseNode["$properties"] or {},
        localNode["$properties"] or {},
        remoteNode["$properties"] or {},
        _appendPath(path, "$properties"),
        conflicts
    )

    if next(merged["$properties"]) == nil then
        merged["$properties"] = nil
    end

    -- Merge attributes
    merged["$attributes"] = _mergeTable(
        baseNode["$attributes"] or {},
        localNode["$attributes"] or {},
        remoteNode["$attributes"] or {},
        _appendPath(path, "$attributes"),
        conflicts
    )

    if next(merged["$attributes"] or {}) == nil then
        merged["$attributes"] = nil
    end

    -- Merge children
    local baseChildren = TreeUtils.getChildKeys(baseNode)
    local localChildren = TreeUtils.getChildKeys(localNode)
    local remoteChildren = TreeUtils.getChildKeys(remoteNode)

    -- Collect all child names
    local allChildren: { [string]: boolean } = {}
    for name in baseChildren do
        allChildren[name] = true
    end
    for name in localChildren do
        allChildren[name] = true
    end
    for name in remoteChildren do
        allChildren[name] = true
    end

    for childName in allChildren do
        local inBase = baseChildren[childName] ~= nil
        local inLocal = localChildren[childName] ~= nil
        local inRemote = remoteChildren[childName] ~= nil
        local childPath = _appendPath(path, childName)

        if inBase and inLocal and inRemote then
            -- All three have it: recurse
            merged[childName] =
                _mergeNodes(baseNode[childName], localNode[childName], remoteNode[childName], childPath, conflicts)
        elseif not inBase and inLocal and not inRemote then
            -- Added locally only
            merged[childName] = TreeUtils.deepClone(localNode[childName])
        elseif not inBase and not inLocal and inRemote then
            -- Added remotely only
            merged[childName] = TreeUtils.deepClone(remoteNode[childName])
        elseif not inBase and inLocal and inRemote then
            -- Both added: merge the two new versions (use empty base)
            local emptyBase = { ["$className"] = localNode[childName]["$className"] }
            merged[childName] =
                _mergeNodes(emptyBase, localNode[childName], remoteNode[childName], childPath, conflicts)
        elseif inBase and not inLocal and inRemote then
            -- Deleted locally: respect the deletion
            -- But check if remote made changes to it
            local remoteDiffs = TreeDiff.diff(baseNode[childName], remoteNode[childName])
            if #remoteDiffs > 0 then
                -- Remote changed it but local deleted it: orphan conflict
                merged[`{childName}_ORPHANED`] = TreeUtils.deepClone(remoteNode[childName])
                table.insert(conflicts, {
                    Path = childPath,
                    LocalValue = nil,
                    RemoteValue = remoteNode[childName],
                })
            end
            -- Otherwise, deletion stands
        elseif inBase and inLocal and not inRemote then
            -- Deleted remotely: respect the deletion
            -- But check if local made changes to it
            local localDiffs = TreeDiff.diff(baseNode[childName], localNode[childName])
            if #localDiffs > 0 then
                -- Local changed it but remote deleted it: orphan conflict
                merged[`{childName}_ORPHANED`] = TreeUtils.deepClone(localNode[childName])
                table.insert(conflicts, {
                    Path = childPath,
                    LocalValue = localNode[childName],
                    RemoteValue = nil,
                })
            end
            -- Otherwise, deletion stands
        elseif inBase and not inLocal and not inRemote then
            -- Both deleted: gone
        end
    end

    return merged
end

function _mergeTable(
    base: { [string]: any },
    local_: { [string]: any },
    remote: { [string]: any },
    path: { string },
    conflicts: { ConflictInfo }
): { [string]: any }
    local merged = {}

    -- Collect all keys
    local allKeys: { [string]: boolean } = {}
    for key in base do
        allKeys[key] = true
    end
    for key in local_ do
        allKeys[key] = true
    end
    for key in remote do
        allKeys[key] = true
    end

    for key in allKeys do
        local baseVal = base[key]
        local localVal = local_[key]
        local remoteVal = remote[key]

        local localChanged = not TreeUtils.deepEqual(baseVal, localVal)
        local remoteChanged = not TreeUtils.deepEqual(baseVal, remoteVal)

        if not localChanged and not remoteChanged then
            -- No changes
            merged[key] = baseVal
        elseif localChanged and not remoteChanged then
            -- Only local changed
            merged[key] = localVal
        elseif not localChanged and remoteChanged then
            -- Only remote changed
            merged[key] = remoteVal
        else
            -- Both changed
            if TreeUtils.deepEqual(localVal, remoteVal) then
                -- Same change: no conflict
                merged[key] = localVal
            else
                -- Actual conflict: keep local, record conflict
                merged[key] = localVal
                table.insert(conflicts, {
                    Path = _appendPath(path, key),
                    LocalValue = localVal,
                    RemoteValue = remoteVal,
                })
            end
        end
    end

    return merged
end

function _appendPath(path: { string }, segment: string): { string }
    local newPath = table.clone(path)
    table.insert(newPath, segment)
    return newPath
end

return Merger
