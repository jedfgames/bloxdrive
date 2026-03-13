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

local function patchRequires(instances: { roblox.Instance })
    local patched = 0

    for _, instance in instances do
        if instance:IsA("LuaSourceContainer") then
            local source = (instance :: any).Source :: string
            -- Studio does not understand @self aliases from .luaurc.
            -- For init.luau containers (ModuleScript with children), @self
            -- refers to the script itself, so require("@self/X") becomes
            -- require(script.X). For non-init files, @self refers to the
            -- parent directory, so it becomes require(script.Parent.X).
            local newSource = source
            local isContainer = instance:IsA("ModuleScript") and #instance:GetChildren() > 0
            if isContainer then
                newSource = string.gsub(source, 'require%("@self/([^"]+)"%)', "require(script.%1)")
            else
                newSource = string.gsub(source, 'require%("@self/([^"]+)"%)', "require(script.Parent.%1)")
            end

            if newSource ~= source then
                (instance :: any).Source = newSource
                patched += 1
            end
        end

        patchRequires(instance:GetChildren())
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
