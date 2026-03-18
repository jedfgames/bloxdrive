#!/usr/bin/env -S lune run

--[[

Lint

Generates Rojo sourcemaps and runs luau-lsp analyze across all Luau
sources. Each group of files is analyzed with the appropriate platform
and sourcemap:

> Source/ and Tests/*.spec.luau - Roblox platform with dev sourcemap
> Tests/E2E/ - Roblox platform with e2e sourcemap
> Scripts/ - Lune platform (no sourcemap)

[Usage] ./Scripts/Lint.luau

--]]

local process = require("@lune/process")

local IGNORE_ARGS = {
    "--ignore=DevPackages/**",
    "--ignore=Packages/**",
    "--ignore=Submodules/**",
}

local function generateSourcemap(projectFile: string, outputFile: string)
    local result = process.exec("rojo", {
        "sourcemap",
        projectFile,
        "--output",
        outputFile,
    })

    if not result.ok then
        print(`Failed to generate sourcemap from "{projectFile}".`)
        print(result.stderr)
        process.exit(1)
    end
end

local function analyze(label: string, args: { string }): boolean
    print(`Analyzing {label}...`)

    local result = process.exec("luau-lsp", args)

    if result.stdout ~= "" then
        print(result.stdout)
    end
    if result.stderr ~= "" then
        print(result.stderr)
    end

    if result.ok then
        print(`No errors found in {label}.`)
    end

    return result.ok
end

local function lint()
    -- Generate sourcemaps
    generateSourcemap("dev.project.json", "sourcemap.json")
    generateSourcemap("e2e.project.json", "e2e-sourcemap.json")

    local allPassed = true

    -- Source/ (Roblox, dev sourcemap)
    local robloxArgs = {
        "analyze",
        "--platform=roblox",
        "--sourcemap=sourcemap.json",
        "--no-flags-enabled",
        table.unpack(IGNORE_ARGS),
    }
    table.insert(robloxArgs, "Source/")
    if not analyze("Source/", robloxArgs) then
        allPassed = false
    end

    -- Tests/E2E/ (Roblox, e2e sourcemap)
    local e2eArgs = {
        "analyze",
        "--platform=roblox",
        "--sourcemap=e2e-sourcemap.json",
        "--no-flags-enabled",
        table.unpack(IGNORE_ARGS),
    }
    table.insert(e2eArgs, "Tests/E2E/")
    if not analyze("Tests/E2E/", e2eArgs) then
        allPassed = false
    end

    -- Scripts/ and Tests/*.spec.luau (Lune, no sourcemap)
    local luneArgs = {
        "analyze",
        "--platform=lune",
        "--no-flags-enabled",
        "--ignore=Source/**",
        "--ignore=Tests/E2E/**",
        table.unpack(IGNORE_ARGS),
    }
    table.insert(luneArgs, "Scripts/")
    table.insert(luneArgs, "Tests/")
    if not analyze("Scripts/ and Tests/", luneArgs) then
        allPassed = false
    end

    if allPassed then
        print("All lint checks passed.")
    else
        process.exit(1)
    end
end

lint()
