--[[

Whitelist.spec

Tests the bloxdrive-registry whitelist admin routes and the write
authorization they gate. Adds a fixture user, verifies it can be
listed and that its minted token authorizes writes, then removes it
and verifies the token no longer works. Uses Lune's net library since
HttpService is not available outside Roblox.

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

local function _removeFixtureUser()
    _adminRequest("DELETE", `/admin/whitelist/{FIXTURE_USER_ID}`)
end

local function _removeFixturePackage(token: string)
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
    _removeFixtureUser()

    local mintedToken: string? = nil

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

    describe("add", function()
        it("should mint a token and return it once", function()
            local response = _adminRequest(
                "POST",
                "/admin/whitelist",
                serde.encode("json", { userId = FIXTURE_USER_ID, name = FIXTURE_NAME })
            )
            assert(response.ok, `Add failed ({response.statusCode}): {response.body}`)

            local decoded = serde.decode("json", response.body)
            expect(decoded.userId).to.equal(FIXTURE_USER_ID)
            expect(decoded.name).to.equal(FIXTURE_NAME)
            expect(decoded.token).to.be.ok()
            expect(#decoded.token > 0).to.equal(true)
            mintedToken = decoded.token
        end)

        it("should reject a missing userId", function()
            local response = _adminRequest("POST", "/admin/whitelist", serde.encode("json", { name = FIXTURE_NAME }))
            expect(response.statusCode).to.equal(400)
        end)
    end)

    describe("list", function()
        it("should include the added user without exposing the token", function()
            local response = _adminRequest("GET", "/admin/whitelist")
            assert(response.ok, `List failed ({response.statusCode})`)

            local decoded = serde.decode("json", response.body)
            local found = nil
            for _, entry in decoded.entries do
                if entry.userId == FIXTURE_USER_ID then
                    found = entry
                    break
                end
            end

            expect(found).to.be.ok()
            expect(found.name).to.equal(FIXTURE_NAME)
            expect(found.token).never.to.be.ok()
        end)
    end)

    describe("write authorization", function()
        it("should authorize a write with the minted token", function()
            assert(mintedToken, "Token required")
            local response = net.request({
                url = `{_url}/packages/{FIXTURE_PACKAGE_ID}/versions/1`,
                method = "PUT",
                headers = {
                    Authorization = `Bearer {mintedToken}`,
                    ["Content-Type"] = "application/json",
                    ["X-Package-Name"] = FIXTURE_NAME,
                },
                body = serde.encode("json", { ["$className"] = "Folder" }),
            })
            assert(response.ok, `Write failed ({response.statusCode}): {response.body}`)
        end)

        it("should reject a write with an unknown token", function()
            local response = net.request({
                url = `{_url}/packages/{FIXTURE_PACKAGE_ID}/versions/2`,
                method = "PUT",
                headers = {
                    Authorization = "Bearer definitely-not-whitelisted",
                    ["Content-Type"] = "application/json",
                },
                body = serde.encode("json", { ["$className"] = "Folder" }),
            })
            expect(response.statusCode).to.equal(401)
        end)
    end)

    describe("remove", function()
        it("should revoke the token so writes are rejected", function()
            assert(mintedToken, "Token required")
            local removeResponse = _adminRequest("DELETE", `/admin/whitelist/{FIXTURE_USER_ID}`)
            assert(removeResponse.ok, `Remove failed ({removeResponse.statusCode})`)

            local writeResponse = net.request({
                url = `{_url}/packages/{FIXTURE_PACKAGE_ID}/versions/3`,
                method = "PUT",
                headers = {
                    Authorization = `Bearer {mintedToken}`,
                    ["Content-Type"] = "application/json",
                },
                body = serde.encode("json", { ["$className"] = "Folder" }),
            })
            expect(writeResponse.statusCode).to.equal(401)
        end)

        it("should return 404 when removing a nonexistent user", function()
            local response = _adminRequest("DELETE", `/admin/whitelist/{FIXTURE_USER_ID}`)
            expect(response.statusCode).to.equal(404)
        end)
    end)

    afterAll(function()
        if mintedToken then
            -- Re-add so cleanup of the fixture package is authorized,
            -- then remove the fixture user again.
            local response = _adminRequest(
                "POST",
                "/admin/whitelist",
                serde.encode("json", { userId = FIXTURE_USER_ID, name = FIXTURE_NAME })
            )
            if response.ok then
                local decoded = serde.decode("json", response.body)
                _removeFixturePackage(decoded.token)
            end
        end
        _removeFixtureUser()
    end)
end
