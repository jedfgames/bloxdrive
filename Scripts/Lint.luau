#!/usr/bin/env -S lune run

--[[

Lint

Runs luau-lsp analyze to report type errors and deprecation warnings.
Analyzes Source with the Roblox dev sourcemap, Tests/E2E with the e2e
sourcemap, and Scripts and Tests with the Lune platform.

[Usage] ./Scripts/Lint.luau

--]]

local Lint = require("../Submodules/luau-cicd/Scripts/Helpers/Lint")

Lint.run({
    Platforms = {
        { Platform = "roblox", Targets = { "/Source" }, RojoProject = "dev.project.json" },
        { Platform = "roblox", Targets = { "/Tests/E2E" }, RojoProject = "e2e.project.json" },
        { Platform = "lune", Targets = { "/Scripts", "/Tests" }, IgnorePatterns = { "Source/**", "Tests/E2E/**" } },
    },
})
