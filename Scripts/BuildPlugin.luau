#!/usr/bin/env -S lune run

--[[

BuildPlugin

Builds the Studio plugin as an .rbxm file using Rojo, patches require
paths for Studio compatibility, and optionally installs the result
into the Roblox Studio plugins directory.

Roblox Studio does not understand @self or ./ require aliases from
.luaurc. This script transforms them after the Rojo build:
> init.luau files: require("@self/X") -> require(script.X)
> Non-init files: require("@self/X") -> require(script.Parent.X)

[Usage] lune run ./Scripts/BuildPlugin.luau [--install]

--]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Dotenv = require("@devpackages/Dotenv")

local PLUGIN_NAME = "rbx-package-loader.rbxm"
local BUILD_PATH = `Build/{PLUGIN_NAME}`

-- Counts how many Parent levels are needed to reach the plugin
-- root from a given instance.
local function _depthFromRoot(instance: roblox.Instance): number
    local depth = 0
    local current = instance.Parent
    while current do
        depth += 1
        current = current.Parent
    end
    return depth
end

-- Builds a script.Parent.Parent... chain to reach the plugin root
-- from a given depth level.
local function _parentChain(depth: number): string
    if depth == 0 then
        return "script"
    end
    local parts = { "script" }
    for _ = 1, depth do
        table.insert(parts, "Parent")
    end
    return table.concat(parts, ".")
end

-- Maps .luaurc alias prefixes to their location in the Rojo tree.
-- Each value is the instance path from the plugin root.
local ALIAS_MAP: { [string]: string } = {
    packages = "Packages",
    rbxpackageloader = "RbxPackageLoader",
}

local function patchRequires(instances: { roblox.Instance })
    local patched = 0

    for _, instance in instances do
        if instance:IsA("LuaSourceContainer") then
            local source = (instance :: any).Source :: string
            local newSource = source
            local isContainer = instance:IsA("ModuleScript") and #instance:GetChildren() > 0

            -- Patch @self aliases. For init.luau containers, @self
            -- refers to the script itself. For non-init files, @self
            -- refers to the parent directory.
            local selfBase = if isContainer then "script" else "script.Parent"
            newSource = string.gsub(newSource, 'require%("@self/([^"]+)"%)', function(path)
                local dotPath = string.gsub(path, "/", ".")
                return `require({selfBase}.{dotPath})`
            end)

            -- Patch alias-based requires (@packages, @rbxpackageloader,
            -- etc.) by computing the relative path from the script to
            -- the plugin root, then appending the target path.
            local depth = _depthFromRoot(instance)
            local rootRef = _parentChain(depth)
            for alias, treePath in ALIAS_MAP do
                -- Bare alias: require("@rbxpackageloader") with no path
                local barePattern = `require%("@{alias}"%)`
                newSource = string.gsub(newSource, barePattern, `require({rootRef}.{treePath})`)

                -- Alias with path: require("@packages/Fusion")
                local pathPattern = `require%("@{alias}/([^"]+)"%)`
                newSource = string.gsub(newSource, pathPattern, function(path)
                    local dotPath = string.gsub(path, "/", ".")
                    return `require({rootRef}.{treePath}.{dotPath})`
                end)
            end

            if newSource ~= source then
                (instance :: any).Source = newSource
                patched += 1
            end
        end

        patched += patchRequires(instance:GetChildren())
    end

    return patched
end

local function buildPlugin()
    local install = table.find(process.args, "--install") ~= nil

    if not fs.isDir("Build") then
        fs.writeDir("Build")
    end

    print("Building plugin with Rojo...")

    local result = process.exec("rojo", {
        "build",
        "plugin.project.json",
        "--output",
        BUILD_PATH,
    })

    if not result.ok then
        print("Rojo build failed.")
        print(result.stderr)
        process.exit(1)
    end

    -- Patch @self requires for Studio compatibility
    local rbxmData = fs.readFile(BUILD_PATH)
    local instances = roblox.deserializeModel(rbxmData)
    local patched = patchRequires(instances)

    local patchedData = roblox.serializeModel(instances)
    fs.writeFile(BUILD_PATH, patchedData)

    local suffix = if patched == 1 then "script" else "scripts"
    print(`Plugin built successfully at "{BUILD_PATH}" ({patched} {suffix} patched).`)

    if not install then
        return
    end

    -- Install to plugins directory
    pcall(Dotenv.load)
    local pluginsDir = process.env.ROBLOX_PLUGINS_DIR
    assert(pluginsDir, "ROBLOX_PLUGINS_DIR is not set in .env or environment.")
    assert(fs.isDir(pluginsDir), `Plugins directory "{pluginsDir}" does not exist.`)

    local installPath = `{pluginsDir}/{PLUGIN_NAME}`
    fs.copy(BUILD_PATH, installPath, { overwrite = true })
    print(`Plugin installed to "{installPath}".`)
end

buildPlugin()
