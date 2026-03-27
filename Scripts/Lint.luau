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
    platforms = {
        { platform = "roblox", targets = { "Source/" }, rojoProject = "dev.project.json" },
        { platform = "roblox", targets = { "Tests/E2E/" }, rojoProject = "e2e.project.json" },
        { platform = "lune", targets = { "Scripts/", "Tests/" }, ignorePatterns = { "Source/**", "Tests/E2E/**" } },
    },
})
