--[[

E2E.spec

End-to-end tests that run against a real Roblox place using the Open
Cloud Luau Execution API. Submits a Luau test script that exercises
Serializer, Deserializer, PropertyReflection, TreeDiff, Merger, and
surgical apply with real instances and ReflectionService.

Each remote test result is mapped to its own it() block so results
integrate with Testable's reporting.

The place must have been published with the source modules already in
it. RunTests.luau handles this automatically when ROBLOX_E2E_API_KEY
is set.

Requires ROBLOX_E2E_API_KEY in .env. Skips gracefully when the key
is not available.

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
local REMOTE_SCRIPT_PATH = "Tests/E2E/RemoteTestScript.luau"

type TestResult = {
    Name: string,
    Passed: boolean,
    Error: string?,
}

local function _loadApiKey(): string?
    pcall(Dotenv.load)
    local key = process.env.ROBLOX_E2E_API_KEY
    if key == nil or key == "" then
        return nil
    end
    return key
end

local function _getTestScript(registryToken: string?): string
    local template = fs.readFile(REMOTE_SCRIPT_PATH)
    local tokenLiteral = if registryToken then `"{registryToken}"` else "nil"
    return string.gsub(template, "__REGISTRY_TOKEN__", tokenLiteral)
end

local function _createTask(apiKey: string, scriptSource: string): string
    local response = net.request({
        url = `{BASE_URL}/universes/{UNIVERSE_ID}/places/{PLACE_ID}/luau-execution-session-tasks`,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["x-api-key"] = apiKey,
        },
        body = serde.encode("json", {
            script = scriptSource,
            timeout = "120s",
        }),
    })

    if not response.ok then
        error(`Task creation failed ({response.statusCode}): {response.body}`)
    end

    local decoded = serde.decode("json", response.body)
    return decoded.path
end

local function _pollTask(apiKey: string, taskPath: string): { [string]: any }
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

        if state == "COMPLETE" or state == "FAILED" then
            return decoded
        end

        if i % 5 == 0 then
            print(`  Polling... attempt {i}/{MAX_POLL_ATTEMPTS}, state: {state}`)
        end
    end

    error("Task timed out after polling limit.")
end

local function _getTaskLogs(apiKey: string, taskPath: string): { string }
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
                    table.insert(allMessages, message)
                end
            end
        end
    end

    return allMessages
end

local function _parseTestResults(logs: { string }): { TestResult }
    local results: { TestResult } = {}

    for _, line in logs do
        local passName = line:match("^%[PASS%] (.+)$")
        if passName then
            table.insert(results, {
                Name = passName,
                Passed = true,
            })
            continue
        end

        local failName, failErr = line:match("^%[FAIL%] (.+) %- (.+)$")
        if failName then
            table.insert(results, {
                Name = failName,
                Passed = false,
                Error = failErr,
            })
        end
    end

    return results
end

local function _runRemoteTests(apiKey: string): { TestResult }
    -- Load registry token to inject into the remote test script
    local registryToken = process.env.REGISTRY_TOKEN
    if registryToken == nil or registryToken == "" then
        registryToken = nil
        print("  REGISTRY_TOKEN not found in .env, registry E2E tests will be skipped.")
    end

    print("  Submitting Luau execution task...")
    local testScript = _getTestScript(registryToken)
    local taskPath = _createTask(apiKey, testScript)

    print("  Polling for task completion...")
    local taskResult = _pollTask(apiKey, taskPath)

    local logs = _getTaskLogs(apiKey, taskPath)

    for _, line in logs do
        print(`    {line}`)
    end

    local results = _parseTestResults(logs)

    -- If the task itself failed (e.g. module load error) and we got
    -- no parseable test results, synthesize a failure from the error
    if taskResult.state == "FAILED" and #results == 0 then
        local errorMsg = "unknown error"
        if taskResult.error then
            errorMsg = `{taskResult.error.code}: {taskResult.error.message}`
        end
        table.insert(results, {
            Name = "Module load",
            Passed = false,
            Error = errorMsg,
        })
    end

    return results
end

return function()
    local apiKey = _loadApiKey()

    if apiKey == nil then
        print("  ROBLOX_E2E_API_KEY not found in .env, E2E tests will be skipped.")
        describe("Open Cloud", function()
            it("skipped (no API key)", function() end)
        end)
        return
    end

    local results = _runRemoteTests(apiKey)

    if #results == 0 then
        describe("Open Cloud", function()
            it("should have returned test results", function()
                error("No test results were parsed from remote execution logs")
            end)
        end)
        return
    end

    describe("Open Cloud", function()
        for _, result in results do
            it(result.Name, function()
                if not result.Passed then
                    error(result.Error or "unknown error")
                end
            end)
        end
    end)
end
