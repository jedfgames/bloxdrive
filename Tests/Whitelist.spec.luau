--[[

Whitelist.spec

Tests the bloxdrive-registry whitelist admin routes and the write
authorization they gate. The ordered add/list/write/rotate/remove flow
runs as a single test so it is not affected by the parallel test
harness, while the independent negative cases run on their own. Uses
Lune's net library since HttpService is not available outside Roblox.

Requires REGISTRY_URL and ADMIN_TOKEN in .env. Skips gracefully when
either is not available.

--]]

local Dotenv = require("@devpackages/Dotenv")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local FIXTURE_USER_ID = "whitelist-spec-fixture-user"
local FIXTURE_NAME = "WhitelistSpecFixture"
local FIXTURE_PACKAGE_ID = "whitelist-spec-fixture-package"
local MISSING_USER_ID = "whitelist-spec-nonexistent-user"

local _url: string? = nil
local _adminToken: string? = nil

local function _loadConfig(): boolean
    pcall(Dotenv.load)
    local url = process.env.REGISTRY_URL
    local adminToken = process.env.ADMIN_TOKEN
    if url == nil or url == "" or adminToken == nil or adminToken == "" then
        return false
    end
    _url = url
    _adminToken = adminToken
    return true
end

local function _adminRequest(method: string, path: string, body: string?): net.FetchResponse
    assert(_url and _adminToken, "Config required")
    return net.request({
        url = `{_url}{path}`,
        method = method :: any,
        headers = {
            Authorization = `Bearer {_adminToken}`,
            ["Content-Type"] = "application/json",
        },
        body = body,
    })
end

local function _addUser(userId: string, name: string): string
    local response = _adminRequest("POST", "/admin/whitelist", serde.encode("json", { userId = userId, name = name }))
    assert(response.ok, `Add failed ({response.statusCode}): {response.body}`)
    return serde.decode("json", response.body).token
end

-- Attempts a version write with the given token and returns the status
-- code so callers can assert authorization outcomes.
local function _writeVersion(token: string, version: number): number
    assert(_url, "Config required")
    local response = net.request({
        url = `{_url}/packages/{FIXTURE_PACKAGE_ID}/versions/{version}`,
        method = "PUT",
        headers = {
            Authorization = `Bearer {token}`,
            ["Content-Type"] = "application/json",
            ["X-Package-Name"] = FIXTURE_NAME,
        },
        body = serde.encode("json", { ["$className"] = "Folder" }),
    })
    return response.statusCode
end

local function _removeUser(userId: string)
    _adminRequest("DELETE", `/admin/whitelist/{userId}`)
end

local function _deletePackage(token: string)
    assert(_url, "Config required")
    net.request({
        url = `{_url}/packages/{FIXTURE_PACKAGE_ID}`,
        method = "DELETE",
        headers = { Authorization = `Bearer {token}` },
    })
end

return function()
    if not _loadConfig() then
        print("  REGISTRY_URL or ADMIN_TOKEN not found in .env, whitelist tests will be skipped.")
        describe("whitelist", function()
            it("skipped (no REGISTRY_URL or ADMIN_TOKEN)", function() end)
        end)
        return
    end

    -- Ensure a clean slate before seeding.
    _removeUser(FIXTURE_USER_ID)

    describe("admin auth", function()
        it("should reject requests without the admin token", function()
            local response = net.request({
                url = `{_url}/admin/whitelist`,
                method = "GET",
            })
            expect(response.statusCode).to.equal(401)
        end)

        it("should reject requests with a wrong admin token", function()
            local response = net.request({
                url = `{_url}/admin/whitelist`,
                method = "GET",
                headers = { Authorization = "Bearer not-the-admin-token" },
            })
            expect(response.statusCode).to.equal(401)
        end)
    end)

    describe("validation", function()
        it("should reject adding a user with a missing userId", function()
            local response = _adminRequest("POST", "/admin/whitelist", serde.encode("json", { name = FIXTURE_NAME }))
            expect(response.statusCode).to.equal(400)
        end)

        it("should reject a non-object body", function()
            local response = _adminRequest("POST", "/admin/whitelist", serde.encode("json", 42))
            expect(response.statusCode).to.equal(400)
        end)

        it("should return 404 when removing a nonexistent user", function()
            local response = _adminRequest("DELETE", `/admin/whitelist/{MISSING_USER_ID}`)
            expect(response.statusCode).to.equal(404)
        end)
    end)

    describe("lifecycle", function()
        it("should add, list, authorize, rotate, and revoke a token", function()
            -- Add mints a token and returns it once.
            local addResponse = _adminRequest(
                "POST",
                "/admin/whitelist",
                serde.encode("json", { userId = FIXTURE_USER_ID, name = FIXTURE_NAME })
            )
            assert(addResponse.ok, `Add failed ({addResponse.statusCode}): {addResponse.body}`)
            local added = serde.decode("json", addResponse.body)
            expect(added.userId).to.equal(FIXTURE_USER_ID)
            expect(added.name).to.equal(FIXTURE_NAME)
            expect(added.token).to.be.ok()
            expect(#added.token > 0).to.equal(true)
            local tokenA = added.token

            -- List includes the user without exposing the token.
            local listResponse = _adminRequest("GET", "/admin/whitelist")
            assert(listResponse.ok, `List failed ({listResponse.statusCode})`)
            local found = nil
            for _, entry in serde.decode("json", listResponse.body).entries do
                if entry.userId == FIXTURE_USER_ID then
                    found = entry
                    break
                end
            end
            expect(found).to.be.ok()
            expect(found.name).to.equal(FIXTURE_NAME)
            expect(found.token).to.never.be.ok()

            -- The minted token authorizes a write; an unknown one does not.
            expect(_writeVersion(tokenA, 1)).to.equal(200)
            expect(_writeVersion("definitely-not-whitelisted", 2)).to.equal(401)

            -- Re-adding the same user rotates the token: a fresh token is
            -- issued, it differs from the old one, the old one is revoked,
            -- and the new one works.
            local tokenB = _addUser(FIXTURE_USER_ID, FIXTURE_NAME)
            expect(tokenB).to.never.equal(tokenA)
            expect(_writeVersion(tokenA, 3)).to.equal(401)
            expect(_writeVersion(tokenB, 3)).to.equal(200)

            -- Removing the user revokes the remaining token.
            local removeResponse = _adminRequest("DELETE", `/admin/whitelist/{FIXTURE_USER_ID}`)
            assert(removeResponse.ok, `Remove failed ({removeResponse.statusCode})`)
            expect(_writeVersion(tokenB, 4)).to.equal(401)

            -- Removing an already-removed user reports 404.
            local secondRemove = _adminRequest("DELETE", `/admin/whitelist/{FIXTURE_USER_ID}`)
            expect(secondRemove.statusCode).to.equal(404)
        end)
    end)

    afterAll(function()
        -- Re-add so cleanup of the fixture package is authorized, delete
        -- the package, then remove the fixture user again.
        local response = _adminRequest(
            "POST",
            "/admin/whitelist",
            serde.encode("json", { userId = FIXTURE_USER_ID, name = FIXTURE_NAME })
        )
        if response.ok then
            _deletePackage(serde.decode("json", response.body).token)
        end
        _removeUser(FIXTURE_USER_ID)
    end)
end
