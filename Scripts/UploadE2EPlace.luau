#!/usr/bin/env -S lune run

--[[

UploadE2EPlace

Builds and uploads the E2E test place to Roblox. Run this once to
set up the place with the latest source modules, then run
`lune run ./Scripts/RunTests.luau E2E` to execute the E2E tests.

[Usage] lune run ./Scripts/UploadE2EPlace.luau

--]]

local Dotenv = require("@devpackages/Dotenv")
local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local UNIVERSE_ID = "9873131552"
local PLACE_ID = "94206881554615"

local function uploadE2EPlace()
    pcall(Dotenv.load)
    local apiKey = process.env.ROBLOX_E2E_API_KEY
    assert(apiKey ~= nil and apiKey ~= "", "ROBLOX_E2E_API_KEY not found in .env")

    if not fs.isDir("Build") then
        fs.writeDir("Build")
    end

    print("Building E2E place with rojo...")
    local result = process.exec("rojo", {
        "build",
        "e2e.project.json",
        "--output",
        "Build/e2e-test.rbxl",
    })

    if not result.ok then
        error(`Rojo build failed: {result.stderr}`)
    end

    local placeData = fs.readFile("Build/e2e-test.rbxl")
    print(`Uploading place ({#placeData} bytes)...`)

    local maxRetries = 5
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
            print(`Place uploaded successfully (version {decoded.versionNumber}).`)
            return
        end

        if response.statusCode == 409 and attempt < maxRetries then
            local waitTime = 10 * attempt
            print(`Upload conflict, retrying in {waitTime} seconds (attempt {attempt}/{maxRetries})...`)
            task.wait(waitTime)
        else
            error(`Place upload failed ({response.statusCode}): {response.body}`)
        end
    end

    error("Place upload failed after all retries.")
end

uploadE2EPlace()
