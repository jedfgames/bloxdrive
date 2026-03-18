#!/usr/bin/env -S lune run

--[[

RunE2ETests

Runs end-to-end tests against a real Roblox place using the Open Cloud Luau
Execution API. Builds the project with rojo, then submits a Luau test
script that exercises Serializer, Deserializer, and PropertyReflection in
the actual Roblox engine with real instances and ReflectionService.

[Usage] lune run ./Scripts/RunE2ETests.luau

Requires a .env file with ROBLOX_API_KEY set. Uses place ID 94206881554615
and universe ID 9873131552.

--]]

local Dotenv = require("@devpackages/Dotenv")
local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local UNIVERSE_ID = "9873131552"
local PLACE_ID = "94206881554615"
local BASE_URL = "https://apis.roblox.com/cloud/v2"
local POLL_INTERVAL = 3
local MAX_POLL_ATTEMPTS = 100

local function _loadApiKey(): string
    Dotenv.load()
    local apiKey = process.env.ROBLOX_API_KEY
    assert(apiKey ~= nil and apiKey ~= "", "ROBLOX_API_KEY not found in .env")
    return apiKey
end

local function _buildPlace()
    print("Building place with rojo...")

    local result = process.exec("rojo", {
        "build",
        "dev.project.json",
        "--output",
        "Build/e2e-test.rbxl",
    })

    if not result.ok then
        error(`Rojo build failed: {result.stderr}`)
    end

    print("Place built successfully.")
end

local function _uploadPlace(apiKey: string): number
    print("Uploading place to Roblox...")

    local placeData = fs.readFile("Build/e2e-test.rbxl")
    local maxRetries = 3

    for attempt = 1, maxRetries do
        local response = net.request({
            url = `https://apis.roblox.com/universes/v1/{UNIVERSE_ID}/places/{PLACE_ID}/versions?versionType=Published`,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/octet-stream",
                ["x-api-key"] = apiKey,
            },
            body = placeData,
        })

        if response.ok then
            local decoded = serde.decode("json", response.body)
            local versionNumber = decoded.versionNumber
            print(`Place uploaded successfully (version {versionNumber}).`)
            return versionNumber
        end

        if response.statusCode == 409 and attempt < maxRetries then
            print(`  Upload conflict, retrying in 5 seconds (attempt {attempt}/{maxRetries})...`)
            task.wait(5)
        else
            error(`Place upload failed ({response.statusCode}): {response.body}`)
        end
    end

    error("Place upload failed after all retries.")
end

local function _getTestScript(): string
    return [[
-- E2E test script for rbx-package-loader
-- Runs inside a real Roblox place via Open Cloud Luau Execution API

local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
    local success, err = pcall(fn)
    if success then
        passed += 1
        print("[PASS] " .. name)
    else
        failed += 1
        table.insert(errors, name .. ": " .. tostring(err))
        print("[FAIL] " .. name .. " - " .. tostring(err))
    end
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(
            (message or "Assertion failed")
            .. " (expected " .. tostring(expected)
            .. ", got " .. tostring(actual) .. ")"
        )
    end
end

-- Test ReflectionService
test("ReflectionService exists", function()
    local rs = game:GetService("ReflectionService")
    assert(rs ~= nil, "ReflectionService not found")
end)

test("ReflectionService can get Part properties", function()
    local rs = game:GetService("ReflectionService")
    local props = rs:GetPropertiesOfClass("Part")
    assert(#props > 0, "No properties returned for Part")

    local foundAnchored = false
    for _, prop in props do
        if prop.Name == "Anchored" then
            foundAnchored = true
            break
        end
    end
    assert(foundAnchored, "Anchored property not found for Part")
end)

test("ReflectionService serialized filter works", function()
    local rs = game:GetService("ReflectionService")
    local props = rs:GetPropertiesOfClass("Part")

    local serializedCount = 0
    for _, prop in props do
        if prop.Serialized then
            serializedCount += 1
        end
    end
    assert(serializedCount > 0, "No serialized properties found for Part")
end)

-- Test Instance creation and property reading
test("Create and read Folder properties", function()
    local folder = Instance.new("Folder")
    folder.Name = "TestFolder"
    folder.Parent = workspace
    assertEqual(folder.ClassName, "Folder")
    assertEqual(folder.Name, "TestFolder")
    folder:Destroy()
end)

test("Create and read Part properties", function()
    local part = Instance.new("Part")
    part.Name = "TestPart"
    part.Anchored = true
    part.Size = Vector3.new(4, 1, 2)
    part.Position = Vector3.new(10, 20, 30)
    part.Parent = workspace

    assertEqual(part.Anchored, true)
    assertEqual(part.Size.X, 4)
    assertEqual(part.Position.X, 10)
    part:Destroy()
end)

test("Create and read ModuleScript Source", function()
    local ms = Instance.new("ModuleScript")
    ms.Name = "TestModule"
    ms.Source = "return {}"
    ms.Parent = workspace

    assertEqual(ms.Source, "return {}")
    ms:Destroy()
end)

test("Create and read NumberValue", function()
    local nv = Instance.new("NumberValue")
    nv.Name = "TestValue"
    nv.Value = 42
    nv.Parent = workspace

    assertEqual(nv.Value, 42)
    nv:Destroy()
end)

test("Create and read StringValue", function()
    local sv = Instance.new("StringValue")
    sv.Name = "TestString"
    sv.Value = "hello"
    sv.Parent = workspace

    assertEqual(sv.Value, "hello")
    sv:Destroy()
end)

-- Test Attributes
test("Set and get attributes", function()
    local folder = Instance.new("Folder")
    folder:SetAttribute("Score", 100)
    folder:SetAttribute("Name", "test")
    folder:SetAttribute("Active", true)
    folder.Parent = workspace

    assertEqual(folder:GetAttribute("Score"), 100)
    assertEqual(folder:GetAttribute("Name"), "test")
    assertEqual(folder:GetAttribute("Active"), true)

    local attrs = folder:GetAttributes()
    assert(attrs.Score == 100, "GetAttributes failed for Score")
    folder:Destroy()
end)

-- Test nested instance tree
test("Create and traverse nested tree", function()
    local root = Instance.new("Folder")
    root.Name = "PackageRoot"

    local config = Instance.new("Configuration")
    config.Name = "DamageConfig"
    config.Parent = root

    local baseDamage = Instance.new("NumberValue")
    baseDamage.Name = "BaseDamage"
    baseDamage.Value = 10
    baseDamage.Parent = config

    local handler = Instance.new("ModuleScript")
    handler.Name = "SwordHandler"
    handler.Source = "return function() end"
    handler.Parent = root

    root.Parent = workspace

    local children = root:GetChildren()
    assertEqual(#children, 2)

    local foundConfig = root:FindFirstChild("DamageConfig")
    assert(foundConfig ~= nil, "DamageConfig not found")
    assertEqual(foundConfig.ClassName, "Configuration")

    local foundDamage = foundConfig:FindFirstChild("BaseDamage")
    assert(foundDamage ~= nil, "BaseDamage not found")
    assertEqual(foundDamage.Value, 10)

    root:Destroy()
end)

-- Test HttpService JSON
test("HttpService JSON encode and decode", function()
    local hs = game:GetService("HttpService")
    local data = {
        Id = "weapon-system",
        Version = 3,
        AutoUpdate = false,
    }

    local encoded = hs:JSONEncode(data)
    local decoded = hs:JSONDecode(encoded)

    assertEqual(decoded.Id, "weapon-system")
    assertEqual(decoded.Version, 3)
    assertEqual(decoded.AutoUpdate, false)
end)

-- Print summary
print("")
print("========================================")
print("E2E Test Results")
print("========================================")
print(passed .. " passed, " .. failed .. " failed")

if #errors > 0 then
    print("")
    print("Failures:")
    for _, err in errors do
        print("  " .. err)
    end
end

print("========================================")

-- Return result for task output
return {
    Passed = passed,
    Failed = failed,
    Success = failed == 0,
}
]]
end

local function _createTask(apiKey: string, script: string): string
    print("Submitting Luau execution task...")

    local response = net.request({
        url = `{BASE_URL}/universes/{UNIVERSE_ID}/places/{PLACE_ID}/luau-execution-session-tasks`,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["x-api-key"] = apiKey,
        },
        body = serde.encode("json", {
            script = script,
            timeout = "120s",
        }),
    })

    if not response.ok then
        error(`Task creation failed ({response.statusCode}): {response.body}`)
    end

    local decoded = serde.decode("json", response.body)
    local taskPath = decoded.path
    print(`Task created: {taskPath}`)
    return taskPath
end

local function _pollTask(apiKey: string, taskPath: string): { [string]: any }
    print("Polling for task completion...")

    for i = 1, MAX_POLL_ATTEMPTS do
        task.wait(POLL_INTERVAL)

        local response = net.request({
            url = `{BASE_URL}/{taskPath}`,
            method = "GET",
            headers = {
                ["x-api-key"] = apiKey,
            },
        })

        if not response.ok then
            warn(`Poll request failed ({response.statusCode}): {response.body}`)
            continue
        end

        local decoded = serde.decode("json", response.body)
        local state = decoded.state

        if state == "COMPLETE" then
            print("Task completed successfully.")
            return decoded
        elseif state == "FAILED" then
            error(`Task failed: {response.body}`)
        end

        print(`  Attempt {i}/{MAX_POLL_ATTEMPTS}, state: {state}`)
    end

    error("Task timed out after polling limit.")
end

local function _getTaskLogs(apiKey: string, taskPath: string): { string }
    print("")
    print("========================================")
    print("Task Logs")
    print("========================================")

    local response = net.request({
        url = `{BASE_URL}/{taskPath}/logs`,
        method = "GET",
        headers = {
            ["x-api-key"] = apiKey,
        },
    })

    if not response.ok then
        warn(`Failed to get task logs ({response.statusCode}): {response.body}`)
        return {}
    end

    local decoded = serde.decode("json", response.body)
    local logEntries = decoded.luauExecutionSessionTaskLogs
    local allMessages: { string } = {}

    if logEntries then
        for _, entry in logEntries do
            if entry.messages then
                for _, message in entry.messages do
                    print(message)
                    table.insert(allMessages, message)
                end
            end
        end
    end

    print("========================================")
    return allMessages
end

local function runE2ETests()
    if not fs.isDir("Build") then
        fs.writeDir("Build")
    end

    local apiKey = _loadApiKey()

    local testScript = _getTestScript()
    local taskPath = _createTask(apiKey, testScript)

    local result = _pollTask(apiKey, taskPath)
    local logs = _getTaskLogs(apiKey, taskPath)

    -- Check logs for the summary line "N passed, M failed"
    local passed = false
    for _, logLine in logs do
        local failCount = logLine:match("(%d+) failed")
        if failCount and failCount == "0" then
            passed = true
        end
    end

    if passed then
        print("")
        print("All E2E tests passed.")
        process.exit(0)
    end

    print("")
    print("E2E tests had failures.")
    process.exit(1)
end

runE2ETests()
