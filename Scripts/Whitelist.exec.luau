#!/usr/bin/env -S lune run

--[[

Whitelist

Manages the bloxdrive registry whitelist through the Worker's admin
routes. Adding a user mints a fresh token and prints it once; hand it
to the teammate to paste into the plugin's "Set Key" prompt. Removing
a user revokes their token immediately without affecting anyone else.

Requires REGISTRY_URL and ADMIN_TOKEN in .env.

[Usage] lune run ./Scripts/Whitelist.luau add <userId> <name>
[Usage] lune run ./Scripts/Whitelist.luau remove <userId>
[Usage] lune run ./Scripts/Whitelist.luau list

--]]

local Dotenv = require("@devpackages/Dotenv")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local function loadConfig(): (string, string)
    pcall(Dotenv.load)

    local url = process.env.REGISTRY_URL
    assert(url ~= nil and url ~= "", "REGISTRY_URL not found in .env")

    local adminToken = process.env.ADMIN_TOKEN
    assert(adminToken ~= nil and adminToken ~= "", "ADMIN_TOKEN not found in .env")

    return url, adminToken
end

local function addUser(url: string, adminToken: string, userId: string, name: string)
    local response = net.request({
        url = `{url}/admin/whitelist`,
        method = "POST",
        headers = {
            Authorization = `Bearer {adminToken}`,
            ["Content-Type"] = "application/json",
        },
        body = serde.encode("json", { userId = userId, name = name }),
    })

    if not response.ok then
        error(`Failed to add user ({response.statusCode}): {response.body}`)
    end

    local decoded = serde.decode("json", response.body)
    print(`Added "{decoded.name}" ({decoded.userId}) to the whitelist.`)
    print("")
    print("Share this token with them now. It will not be shown again.")
    print("")
    print(`  {decoded.token}`)
    print("")
end

local function removeUser(url: string, adminToken: string, userId: string)
    local response = net.request({
        url = `{url}/admin/whitelist/{userId}`,
        method = "DELETE",
        headers = { Authorization = `Bearer {adminToken}` },
    })

    if response.statusCode == 404 then
        error(`No whitelist entry found for user "{userId}".`)
    end
    if not response.ok then
        error(`Failed to remove user ({response.statusCode}): {response.body}`)
    end

    print(`Removed user "{userId}" from the whitelist.`)
end

local function listUsers(url: string, adminToken: string)
    local response = net.request({
        url = `{url}/admin/whitelist`,
        method = "GET",
        headers = { Authorization = `Bearer {adminToken}` },
    })

    if not response.ok then
        error(`Failed to list users ({response.statusCode}): {response.body}`)
    end

    local decoded = serde.decode("json", response.body)
    local entries = decoded.entries

    if #entries == 0 then
        print("The whitelist is empty.")
        return
    end

    print(`{#entries} whitelisted {if #entries == 1 then "user" else "users"}.`)
    for _, entry in entries do
        print(`  {entry.userId}  {entry.name}  (added {entry.createdAt})`)
    end
end

local function usage()
    print("[Usage] lune run ./Scripts/Whitelist.luau add <userId> <name>")
    print("[Usage] lune run ./Scripts/Whitelist.luau remove <userId>")
    print("[Usage] lune run ./Scripts/Whitelist.luau list")
end

local function whitelist()
    local command = process.args[1]

    if command == "add" then
        local userId = process.args[2]
        local name = process.args[3]
        if not userId or not name then
            usage()
            process.exit(1)
        end
        local url, adminToken = loadConfig()
        addUser(url, adminToken, userId, name)
    elseif command == "remove" then
        local userId = process.args[2]
        if not userId then
            usage()
            process.exit(1)
        end
        local url, adminToken = loadConfig()
        removeUser(url, adminToken, userId)
    elseif command == "list" then
        local url, adminToken = loadConfig()
        listUsers(url, adminToken)
    else
        usage()
        process.exit(1)
    end
end

whitelist()
