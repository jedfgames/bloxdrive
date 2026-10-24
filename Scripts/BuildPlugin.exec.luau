#!/usr/bin/env -S lune run

--[[

BuildPlugin.exec

Builds the Studio plugin as an .rbxm file using Rojo and optionally
installs the result into the Roblox Studio plugins directory. The Rojo
fork resolves .luaurc aliases and init.plugin.luau files automatically,
so no post-build patching is needed.

[Usage] ./Scripts/BuildPlugin.exec.luau [--install]

--]]

const fs = require("@lune/fs")
const process = require("@lune/process")

const Dotenv = require("@devpackages/Dotenv")

const PLUGIN_NAME = "Bloxdrive.rbxm"
const BUILD_PATH = `Build/{PLUGIN_NAME}`

const BuildPlugin = {}

function BuildPlugin.exec()
    const install = table.find(process.args, "--install") ~= nil

    if not fs.isDir("Build") then
        fs.writeDir("Build")
    end

    print("Building plugin with Rojo...")

    const result = process.exec("rojo", {
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
    const pluginsDir = process.env.ROBLOX_PLUGINS_DIR
    assert(pluginsDir, "ROBLOX_PLUGINS_DIR is not set in .env or environment.")
    assert(fs.isDir(pluginsDir), `Plugins directory "{pluginsDir}" does not exist.`)

    const installPath = `{pluginsDir}/{PLUGIN_NAME}`
    fs.copy(BUILD_PATH, installPath, { overwrite = true })
    print(`Plugin installed to "{installPath}".`)
end

BuildPlugin.exec()
