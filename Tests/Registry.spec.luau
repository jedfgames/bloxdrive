--[[

Registry.spec

Tests for fetching package data from the bloxdrive-registry
Cloudflare Worker. Creates a temporary package, verifies fetch
operations, then cleans up. Uses Lune's net library since
HttpService is not available outside Roblox.

Requires REGISTRY_TOKEN in .env (a whitelisted token minted via
Scripts/Whitelist.exec.luau). Skips gracefully when the token is not
available.

--]]

const Dotenv = require("@devpackages/Dotenv")
const net = require("@lune/net")
const process = require("@lune/process")
const serde = require("@lune/serde")

const TreeUtils = require("@bloxdrive/TreeUtils")

const REGISTRY_URL = "https://rbx-package-registry.batchprogrammer314.workers.dev"
const TEST_PACKAGE_ID = "registry-spec-fixture"

local _token: string? = nil

const function _loadToken(): string?
    pcall(Dotenv.load)
    const token = process.env.REGISTRY_TOKEN
    if token == nil or token == "" then
        return nil
    end
    return token
end

-- Seed test data before running tests
const function _seedTestPackage()
    assert(_token, "Token required")

    const v1 = {
        ["$className"] = "Folder",
        Health = {
            ["$className"] = "NumberValue",
            ["$properties"] = { Value = 100 },
        },
    }

    const v2 = {
        ["$className"] = "Folder",
        Health = {
            ["$className"] = "NumberValue",
            ["$properties"] = { Value = 200 },
        },
        Speed = {
            ["$className"] = "NumberValue",
            ["$properties"] = { Value = 16 },
        },
    }

    for version, tree in { v1, v2 } do
        net.request({
            url = `{REGISTRY_URL}/packages/{TEST_PACKAGE_ID}/versions/{version}`,
            method = "PUT",
            headers = {
                Authorization = `Bearer {_token}`,
                ["Content-Type"] = "application/json",
                ["X-Package-Name"] = "RegistrySpecFixture",
            },
            body = serde.encode("json", tree),
        })
    end
end

const function _cleanupTestPackage()
    assert(_token, "Token required")
    net.request({
        url = `{REGISTRY_URL}/packages/{TEST_PACKAGE_ID}`,
        method = "DELETE",
        headers = { Authorization = `Bearer {_token}` },
    })
end

return function()
    _token = _loadToken()

    if _token == nil then
        print("  REGISTRY_TOKEN not found in .env, registry tests will be skipped.")
        describe("fetch", function()
            it("skipped (no REGISTRY_TOKEN)", function() end)
        end)
        return
    end

    _seedTestPackage()

    describe("fetch", function()
        it("should fetch package metadata", function()
            const response = net.request({
                url = `{REGISTRY_URL}/packages/{TEST_PACKAGE_ID}`,
                method = "GET",
                headers = { Authorization = `Bearer {_token}` },
            })

            assert(response.ok, `Metadata fetch failed ({response.statusCode})`)

            const metadata = serde.decode("json", response.body)
            expect(metadata.name).to.equal("RegistrySpecFixture")
            expect(metadata.latestVersion).to.equal(2)
        end)

        it("should fetch a specific version tree", function()
            const response = net.request({
                url = `{REGISTRY_URL}/packages/{TEST_PACKAGE_ID}/versions/1`,
                method = "GET",
                headers = { Authorization = `Bearer {_token}` },
            })

            assert(response.ok, `Version fetch failed ({response.statusCode})`)

            const tree = serde.decode("json", response.body)
            expect(tree["$className"]).to.equal("Folder")
            expect(tree.Health["$properties"].Value).to.equal(100)
        end)

        it("should fetch the latest version tree", function()
            const response = net.request({
                url = `{REGISTRY_URL}/packages/{TEST_PACKAGE_ID}/versions/2`,
                method = "GET",
                headers = { Authorization = `Bearer {_token}` },
            })

            assert(response.ok, `Version fetch failed ({response.statusCode})`)

            const tree = serde.decode("json", response.body)
            expect(tree["$className"]).to.equal("Folder")
            expect(tree.Health["$properties"].Value).to.equal(200)
            expect(tree.Speed).to.be.ok()

            local childCount = 0
            for key in TreeUtils.getChildKeys(tree) do
                childCount += 1
            end
            expect(childCount).to.equal(2)
        end)

        it("should return 404 for nonexistent version", function()
            const response = net.request({
                url = `{REGISTRY_URL}/packages/{TEST_PACKAGE_ID}/versions/999`,
                method = "GET",
                headers = { Authorization = `Bearer {_token}` },
            })

            expect(response.statusCode).to.equal(404)
        end)
    end)

    afterAll(function()
        _cleanupTestPackage()
    end)
end
