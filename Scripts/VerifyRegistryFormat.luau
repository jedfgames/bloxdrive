#!/usr/bin/env -S lune run

--[[

VerifyRegistryFormat

Reads the hierarchical registry files for each example package,
reassembles them into a TreeNode, deserializes into Lune instances,
serializes to rbxm, then deserializes back and compares. This verifies
the registry format produces valid Roblox instance trees.

--]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local REGISTRY_PATH = "../rbx-package-registry"

local PACKAGES = {
    { Id = "shield-kit", Version = 1 },
    { Id = "shield-kit", Version = 2 },
    { Id = "ui-framework", Version = 1 },
    { Id = "weapon-system", Version = 1 },
    { Id = "weapon-system", Version = 2 },
    { Id = "weapon-system", Version = 3 },
}

local function reassembleAtPrefix(files: { [string]: any }, prefix: string): { [string]: any }
    local instancePath = if prefix == "" then "instance.json" else `{prefix}/instance.json`
    local node = {}

    local metadata = files[instancePath]
    assert(metadata ~= nil, `Missing metadata at "{instancePath}"`)

    for key, value in metadata do
        node[key] = value
    end

    local childrenFound: { [string]: string } = {}

    for path in files do
        if path == instancePath then
            continue
        end

        local relativePath: string
        if prefix == "" then
            relativePath = path
        elseif string.sub(path, 1, #prefix + 1) == `{prefix}/` then
            relativePath = string.sub(path, #prefix + 2)
        else
            continue
        end

        local slashPos = string.find(relativePath, "/")
        if slashPos then
            local dirName = string.sub(relativePath, 1, slashPos - 1)
            if not childrenFound[dirName] then
                childrenFound[dirName] = "directory"
            end
        else
            if string.sub(relativePath, -5) == ".json" then
                local childName = string.sub(relativePath, 1, -6)
                childrenFound[childName] = "file"
            end
        end
    end

    for childName, childType in childrenFound do
        if childType == "directory" then
            local childPrefix = if prefix == "" then childName else `{prefix}/{childName}`
            node[childName] = reassembleAtPrefix(files, childPrefix)
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

local function deserializeNode(name: string, node: { [string]: any }, parent: roblox.Instance): roblox.Instance
    local className = node["$className"]
    local instance = roblox.Instance.new(className)

    if node["$properties"] then
        for propName, propValue in node["$properties"] do
            if type(propValue) == "table" then
                continue
            end
            pcall(function()
                (instance :: any)[propName] = propValue
            end)
        end
    end

    for key, child in node do
        if string.sub(key, 1, 1) == "$" then
            continue
        end
        if type(child) ~= "table" or child["$className"] == nil then
            continue
        end
        deserializeNode(key, child, instance)
    end

    instance.Name = name
    instance.Parent = parent
    return instance
end

local function readFilesFromDir(dir: string): { [string]: any }
    local files: { [string]: any } = {}

    local function walkDir(currentDir: string, prefix: string)
        for _, entry in fs.readDir(currentDir) do
            local fullPath = `{currentDir}/{entry}`
            if fs.isDir(fullPath) then
                local newPrefix = if prefix == "" then entry else `{prefix}/{entry}`
                walkDir(fullPath, newPrefix)
            elseif string.sub(entry, -5) == ".json" and entry ~= "manifest.json" then
                local relativePath = if prefix == "" then entry else `{prefix}/{entry}`
                local content = fs.readFile(fullPath)
                files[relativePath] = serde.decode("json", content)
            end
        end
    end

    walkDir(dir, "")
    return files
end

local function countChildren(node: { [string]: any }): number
    local count = 0
    for key, value in node do
        if string.sub(key, 1, 1) ~= "$" and type(value) == "table" and value["$className"] then
            count += 1
        end
    end
    return count
end

local function countAllDescendants(node: { [string]: any }): number
    local count = 0
    for key, value in node do
        if string.sub(key, 1, 1) ~= "$" and type(value) == "table" and value["$className"] then
            count += 1
            count += countAllDescendants(value)
        end
    end
    return count
end

local function verifyRegistryFormat()
    assert(fs.isDir(REGISTRY_PATH), `Registry not found at "{REGISTRY_PATH}". Run from rbx-package-loader root.`)

    local passCount = 0
    local failCount = 0

    print("Verifying registry format for all example packages\n")

    for _, pkg in PACKAGES do
        local versionDir = `{REGISTRY_PATH}/packages/{pkg.Id}/versions/{pkg.Version}`

        if not fs.isDir(versionDir) then
            print(`SKIP: {pkg.Id} v{pkg.Version} (directory not found)`)
            continue
        end

        local files = readFilesFromDir(versionDir)
        local tree = reassembleAtPrefix(files, "")

        local descendants = countAllDescendants(tree)
        local children = countChildren(tree)

        local folder = roblox.Instance.new("Folder")
        folder.Name = pkg.Id
        local root = deserializeNode(pkg.Id, tree, folder)

        local rbxmData = roblox.serializeModel({ root })
        local rebuilt = roblox.deserializeModel(rbxmData)

        local rebuildChildren = 0
        if #rebuilt > 0 then
            rebuildChildren = #rebuilt[1]:GetChildren()
        end

        local passed = #rebuilt > 0
            and rebuilt[1].Name == pkg.Id
            and rebuilt[1].ClassName == tree["$className"]
            and rebuildChildren == children

        if passed then
            passCount += 1
            print(`PASS: {pkg.Id} v{pkg.Version} ({descendants} descendants, {children} children, rbxm round-trip OK)`)
        else
            failCount += 1
            print(`FAIL: {pkg.Id} v{pkg.Version}`)
            if #rebuilt == 0 then
                print("  No instances in rebuilt model")
            else
                print(`  Name: {rebuilt[1].Name} (expected {pkg.Id})`)
                print(`  ClassName: {rebuilt[1].ClassName} (expected {tree["$className"]})`)
                print(`  Children: {rebuildChildren} (expected {children})`)
            end
        end

        fs.writeFile(`/tmp/rbx-registry-{pkg.Id}-v{pkg.Version}.rbxm`, rbxmData)
    end

    print(`\n{passCount} passed, {failCount} failed.`)

    if failCount > 0 then
        process.exit(1)
    end
end

verifyRegistryFormat()
