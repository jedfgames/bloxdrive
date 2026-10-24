#!/usr/bin/env -S lune run

--[[

Lint.exec

Runs luau-lsp analyze to report type errors and deprecation warnings.
Analyzes Source with the Roblox dev sourcemap, Tests/E2E with the e2e
sourcemap, and Scripts and Tests with the Lune platform.

[Usage] ./Scripts/Lint.exec.luau

--]]

const Lint = {}

function Lint.exec()
    require("@submodules/luau-cicd/Scripts/Helpers/Lint").run({
        Platforms = {
            { Platform = "roblox", Targets = { "/Source" }, RojoProject = "dev.project.json" },
            { Platform = "roblox", Targets = { "/Tests/E2E" }, RojoProject = "e2e.project.json" },
            { Platform = "lune", Targets = { "/Scripts", "/Tests" }, IgnorePatterns = { "Source/**", "Tests/E2E/**" } },
        },
    })
end

Lint.exec()
