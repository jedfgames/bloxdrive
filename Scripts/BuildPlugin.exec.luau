#!/usr/bin/env -S lune run

--[[

BuildPlugin

Builds the Studio plugin as an .rbxm file using Rojo and optionally
installs the result into the Roblox Studio plugins directory. The Rojo
fork resolves .luaurc aliases and init.plugin.luau files automatically,
so no post-build patching is needed.

[Usage] lune run ./Scripts/BuildPlugin.luau [--install]

--]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Dotenv = require("@devpackages/Dotenv")

local PLUGIN_NAME = "Bloxdrive.rbxm"
local BUILD_PATH = `Build/{PLUGIN_NAME}`

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

    print(`Plugin built successfully at "{BUILD_PATH}".`)

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
