#!/usr/bin/env -S lune run

--[[

Lint

Downloads Roblox type definitions if missing, generates a Rojo sourcemap,
and runs luau-lsp analyze to report type errors and deprecation warnings.

[Usage] lune run ./Scripts/Lint.luau

--]]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")

local DEFS_DIR = ".luau-lsp"
local DEFS_FILE = `{DEFS_DIR}/globalTypes.d.luau`
local DEFS_URL = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"
local PROJECT_FILE = "dev.project.json"
local SOURCEMAP_FILE = "sourcemap.json"

local function lint()
    -- Download definitions if missing
    if not fs.isFile(DEFS_FILE) then
        print("Downloading Roblox type definitions...")

        if not fs.isDir(DEFS_DIR) then
            fs.writeDir(DEFS_DIR)
        end

        local response = net.request(DEFS_URL)

        if not response.ok then
            print(`Failed to download definitions (HTTP {response.statusCode}).`)
            process.exit(1)
        end

        fs.writeFile(DEFS_FILE, response.body)
        print(`Saved definitions to "{DEFS_FILE}".`)
    end

    -- Generate sourcemap
    local sourcemapResult = process.exec("rojo", {
        "sourcemap",
        PROJECT_FILE,
        "--output",
        SOURCEMAP_FILE,
    })

    if not sourcemapResult.ok then
        print("Failed to generate sourcemap.")
        print(sourcemapResult.stderr)
        process.exit(1)
    end

    -- Run luau-lsp analyze
    local analyzeResult = process.exec("luau-lsp", {
        "analyze",
        `--sourcemap={SOURCEMAP_FILE}`,
        `--defs={DEFS_FILE}`,
        "--ignore=DevPackages/**",
        "--ignore=Packages/**",
        "--ignore=Submodules/**",
        "Source/",
    })

    if analyzeResult.stdout ~= "" then
        print(analyzeResult.stdout)
    end
    if analyzeResult.stderr ~= "" then
        print(analyzeResult.stderr)
    end

    if analyzeResult.ok then
        print("No lint errors found.")
    else
        process.exit(1)
    end
end

lint()
