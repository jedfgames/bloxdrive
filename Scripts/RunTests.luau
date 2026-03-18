#!/usr/bin/env -S lune run

--[[

RunTests

Executes all test suites and exits with appropriate status code. Optionally pass a test
name as an argument to run only that test suite.

[Usage] lune run ./Scripts/RunTests.luau [TestName]

--]]

local Dotenv = require("@devpackages/Dotenv")
local Testable = require("@devpackages/Testable")
local process = require("@lune/process")

pcall(Dotenv.load)

Testable.configure({
    Verbose = true,
})

-- Upload the E2E place before running tests so remote tests use
-- the latest source code. Skips if ROBLOX_E2E_API_KEY is not set.
local function uploadE2EPlace()
    local apiKey = process.env.ROBLOX_E2E_API_KEY
    if not apiKey or apiKey == "" then
        print("ROBLOX_E2E_API_KEY not set, skipping E2E place upload.")
        return
    end

    print("Uploading E2E place...")
    local result = process.exec("lune", { "run", "./Scripts/UploadE2EPlace.luau" })
    if not result.ok then
        print(`Warning: E2E place upload failed. {result.stderr}`)
        print("E2E tests may run against stale code.")
    end
end

uploadE2EPlace()

local TESTS = {
    { Name = "Deserializer", Func = require("../Tests/Deserializer.spec") },
    { Name = "E2E", Func = require("../Tests/E2E.spec") },
    { Name = "Merger", Func = require("../Tests/Merger.spec") },
    { Name = "Registry", Func = require("../Tests/Registry.spec") },
    { Name = "RegistryLifecycle", Func = require("../Tests/RegistryLifecycle.spec") },
    { Name = "Serializer", Func = require("../Tests/Serializer.spec") },
    { Name = "TreeDiff", Func = require("../Tests/TreeDiff.spec") },
    { Name = "TreeUtils", Func = require("../Tests/TreeUtils.spec") },
}

local function runTests()
    local filterName = process.args[1]
    local testsToRun = TESTS

    if filterName then
        testsToRun = {}
        for _, test in TESTS do
            if test.Name == filterName then
                table.insert(testsToRun, test)
            end
        end

        if #testsToRun == 0 then
            print(`No test suite found with name "{filterName}".`)
            print("Available test suites:")
            for _, test in TESTS do
                print(`- {test.Name}`)
            end
            process.exit(1)
        end
    end

    local _, passed = Testable.run(testsToRun)
    process.exit(if passed then 0 else 1)
end

runTests()
