--[[

RegistryLifecycle.spec

Stress tests that create, publish, update, fetch, diff, merge, and
verify real packages on the bloxdrive-registry Cloudflare Worker.
Test packages use a "test-" prefix in their ID so they can be cleaned
up without affecting real data. Exercises every registry operation
end-to-end using Lune's net library.

Requires REGISTRY_TOKEN in .env with write access. Skips gracefully
when the token is not available.

--]]

local Dotenv = require("@devpackages/Dotenv")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Merger = require("@bloxdrive/Merger")
local TreeDiff = require("@bloxdrive/TreeDiff")
local TreeUtils = require("@bloxdrive/TreeUtils")

local REGISTRY_URL = "https://rbx-package-registry.batchprogrammer314.workers.dev"
local TEST_PREFIX = "test-"

local MAX_RETRIES = 3
local RETRY_DELAY = 1

local _token: string? = nil

-- Collected test package IDs for cleanup in afterAll
local _testPackageIds: { string } = {}

-- Registry API helpers ------------------------------------------------

local function _request(
    method: string,
    path: string,
    body: string?,
    extraHeaders: { [string]: string }?
): net.FetchResponse
    assert(_token, "Token required")

    local headers: { [string]: string } = {
        Authorization = `Bearer {_token}`,
    }

    if body then
        headers["Content-Type"] = "application/json"
    end

    if extraHeaders then
        for key, value in extraHeaders do
            headers[key] = value
        end
    end

    for attempt = 1, MAX_RETRIES do
        local ok, response = pcall(net.request, {
            url = `{REGISTRY_URL}{path}`,
            method = method,
            headers = headers,
            body = body,
        })

        if not ok then
            if attempt < MAX_RETRIES then
                task.wait(RETRY_DELAY * attempt)
                continue
            end
            error(`Request failed after {MAX_RETRIES} attempts: {response}`)
        end

        return response
    end

    error("Exhausted all retries")
end

local function _get(path: string): string
    local response = _request("GET", path)
    assert(response.ok, `GET {path} failed ({response.statusCode}): {response.body}`)
    return response.body
end

local function _put(path: string, body: string, extraHeaders: { [string]: string }?)
    local response = _request("PUT", path, body, extraHeaders)
    assert(response.ok, `PUT {path} failed ({response.statusCode}): {response.body}`)
end

-- Generate a unique test package ID
local function _generatePackageId(): string
    local chars = "0123456789abcdef"
    local result = {}
    for _ = 1, 16 do
        local idx = math.random(1, #chars)
        table.insert(result, string.sub(chars, idx, idx))
    end
    local id = `{TEST_PREFIX}{table.concat(result)}`
    table.insert(_testPackageIds, id)
    return id
end

-- Publishing helpers ------------------------------------------------

local function _publishVersion(packageId: string, packageName: string, tree: { [string]: any }, expectedVersion: number)
    local treeJson = serde.encode("json", tree)
    _put(`/packages/{packageId}/versions/{expectedVersion}`, treeJson, {
        ["X-Package-Name"] = packageName,
    })
end

local function _fetchMetadata(packageId: string): { [string]: any }
    local body = _get(`/packages/{packageId}`)
    return serde.decode("json", body)
end

local function _fetchVersionTree(packageId: string, version: number): { [string]: any }
    local body = _get(`/packages/{packageId}/versions/{version}`)
    return serde.decode("json", body)
end

-- Cleanup helper
local function _cleanupTestPackages()
    assert(_token, "Token required")

    if #_testPackageIds == 0 then
        return
    end

    print(`  Cleaning up {#_testPackageIds} test packages...`)

    local deleted = 0
    local total = #_testPackageIds

    for _, packageId in _testPackageIds do
        task.spawn(function()
            _request("DELETE", `/packages/{packageId}`)
            deleted += 1
            if deleted % 10 == 0 or deleted == total then
                print(`    Deleted {deleted}/{total} packages`)
            end
        end)
    end

    while deleted < total do
        task.wait(0.5)
    end
end

-- Test trees --------------------------------------------------------

local function _makeSimpleTree(): { [string]: any }
    return {
        ["$className"] = "Folder",
        Health = {
            ["$className"] = "NumberValue",
            ["$properties"] = { Value = 100 },
        },
        Label = {
            ["$className"] = "StringValue",
            ["$properties"] = { Value = "hello" },
        },
    }
end

local function _makeComplexTree(): { [string]: any }
    return {
        ["$className"] = "Folder",
        Config = {
            ["$className"] = "Configuration",
            MaxHealth = {
                ["$className"] = "NumberValue",
                ["$properties"] = { Value = 100 },
            },
            Speed = {
                ["$className"] = "NumberValue",
                ["$properties"] = { Value = 16 },
            },
            Settings = {
                ["$className"] = "Folder",
                Debug = {
                    ["$className"] = "BoolValue",
                    ["$properties"] = { Value = false },
                },
                LogLevel = {
                    ["$className"] = "StringValue",
                    ["$properties"] = { Value = "warn" },
                },
            },
        },
        Assets = {
            ["$className"] = "Folder",
            Sword = {
                ["$className"] = "Part",
                ["$properties"] = {
                    Anchored = true,
                    size = { Vector3 = { 1, 4, 0.2 } },
                },
            },
        },
        Handler = {
            ["$className"] = "ModuleScript",
            ["$properties"] = { Source = "return { version = 1 }" },
        },
    }
end

local function _makeTreeWithAttributes(): { [string]: any }
    return {
        ["$className"] = "Folder",
        ["$attributes"] = {
            PackageName = "TestAttrPackage",
            Version = 1,
            IsTest = true,
        },
        Data = {
            ["$className"] = "Folder",
            ["$attributes"] = {
                Category = "test",
                Priority = 5,
            },
            Value = {
                ["$className"] = "NumberValue",
                ["$properties"] = { Value = 42 },
            },
        },
    }
end

return function()
    pcall(Dotenv.load)
    _token = process.env.REGISTRY_TOKEN

    if _token == nil or _token == "" then
        _token = nil
        print("  REGISTRY_TOKEN not found in .env, lifecycle tests will be skipped.")
        describe("lifecycle", function()
            it("skipped (no REGISTRY_TOKEN)", function() end)
        end)
        return
    end

    describe("publish and fetch", function()
        it("should publish a new package and fetch it back", function()
            local packageId = _generatePackageId()

            local tree = _makeSimpleTree()
            _publishVersion(packageId, "SimpleTest", tree, 1)

            local metadata = _fetchMetadata(packageId)
            expect(metadata.name).to.equal("SimpleTest")
            expect(metadata.latestVersion).to.equal(1)

            local fetched = _fetchVersionTree(packageId, 1)
            expect(fetched["$className"]).to.equal("Folder")
            expect(fetched.Health).to.be.ok()
            expect(fetched.Health["$className"]).to.equal("NumberValue")
            expect(fetched.Health["$properties"].Value).to.equal(100)
            expect(fetched.Label).to.be.ok()
            expect(fetched.Label["$properties"].Value).to.equal("hello")
        end)

        it("should publish multiple versions and fetch each", function()
            local packageId = _generatePackageId()

            local v1 = _makeSimpleTree()
            _publishVersion(packageId, "MultiVersion", v1, 1)

            local v2 = TreeUtils.deepClone(v1)
            v2.Health["$properties"].Value = 200
            _publishVersion(packageId, "MultiVersion", v2, 2)

            local v3 = TreeUtils.deepClone(v2)
            v3.Score = {
                ["$className"] = "NumberValue",
                ["$properties"] = { Value = 999 },
            }
            _publishVersion(packageId, "MultiVersion", v3, 3)

            local metadata = _fetchMetadata(packageId)
            expect(metadata.latestVersion).to.equal(3)

            expect(_fetchVersionTree(packageId, 1).Health["$properties"].Value).to.equal(100)
            expect(_fetchVersionTree(packageId, 2).Health["$properties"].Value).to.equal(200)

            local fetched3 = _fetchVersionTree(packageId, 3)
            expect(fetched3.Health["$properties"].Value).to.equal(200)
            expect(fetched3.Score["$properties"].Value).to.equal(999)
        end)

        it("should publish a complex nested tree", function()
            local packageId = _generatePackageId()

            local tree = _makeComplexTree()
            _publishVersion(packageId, "ComplexTest", tree, 1)

            local fetched = _fetchVersionTree(packageId, 1)
            expect(fetched["$className"]).to.equal("Folder")
            expect(fetched.Config["$className"]).to.equal("Configuration")
            expect(fetched.Config.MaxHealth["$properties"].Value).to.equal(100)
            expect(fetched.Config.Settings.Debug["$properties"].Value).to.equal(false)
            expect(fetched.Config.Settings.LogLevel["$properties"].Value).to.equal("warn")
            expect(fetched.Assets.Sword["$properties"].Anchored).to.equal(true)
            expect(fetched.Handler["$properties"].Source).to.equal("return { version = 1 }")
        end)

        it("should publish a tree with attributes", function()
            local packageId = _generatePackageId()

            local tree = _makeTreeWithAttributes()
            _publishVersion(packageId, "AttrTest", tree, 1)

            local fetched = _fetchVersionTree(packageId, 1)
            expect(fetched["$attributes"].PackageName).to.equal("TestAttrPackage")
            expect(fetched["$attributes"].Version).to.equal(1)
            expect(fetched["$attributes"].IsTest).to.equal(true)
            expect(fetched.Data["$attributes"].Category).to.equal("test")
            expect(fetched.Data["$attributes"].Priority).to.equal(5)
        end)
    end)

    describe("diff across versions", function()
        it("should detect property changes between versions", function()
            local packageId = _generatePackageId()

            local v1 = _makeSimpleTree()
            _publishVersion(packageId, "DiffPropTest", v1, 1)

            local v2 = TreeUtils.deepClone(v1)
            v2.Health["$properties"].Value = 999
            _publishVersion(packageId, "DiffPropTest", v2, 2)

            local fetched1 = _fetchVersionTree(packageId, 1)
            local fetched2 = _fetchVersionTree(packageId, 2)

            local ops = TreeDiff.diff(fetched1, fetched2)
            expect(#ops > 0).to.equal(true)

            local foundHealthChange = false
            for _, op in ops do
                if op.Kind == "Modify" then
                    local pathStr = table.concat(op.Path, ".")
                    if string.find(pathStr, "Health") and string.find(pathStr, "Value") then
                        foundHealthChange = true
                        expect(op.OldValue).to.equal(100)
                        expect(op.NewValue).to.equal(999)
                    end
                end
            end
            expect(foundHealthChange).to.equal(true)
        end)

        it("should detect added children between versions", function()
            local packageId = _generatePackageId()

            local v1 = _makeSimpleTree()
            _publishVersion(packageId, "DiffAddTest", v1, 1)

            local v2 = TreeUtils.deepClone(v1)
            v2.NewChild = {
                ["$className"] = "BoolValue",
                ["$properties"] = { Value = true },
            }
            _publishVersion(packageId, "DiffAddTest", v2, 2)

            local ops = TreeDiff.diff(_fetchVersionTree(packageId, 1), _fetchVersionTree(packageId, 2))

            local foundAdd = false
            for _, op in ops do
                if op.Kind == "Add" and op.Path[1] == "NewChild" then
                    foundAdd = true
                end
            end
            expect(foundAdd).to.equal(true)
        end)

        it("should detect removed children between versions", function()
            local packageId = _generatePackageId()

            local v1 = _makeSimpleTree()
            _publishVersion(packageId, "DiffRemoveTest", v1, 1)

            local v2 = TreeUtils.deepClone(v1)
            v2.Label = nil
            _publishVersion(packageId, "DiffRemoveTest", v2, 2)

            local ops = TreeDiff.diff(_fetchVersionTree(packageId, 1), _fetchVersionTree(packageId, 2))

            local foundRemove = false
            for _, op in ops do
                if op.Kind == "Remove" and op.Path[1] == "Label" then
                    foundRemove = true
                end
            end
            expect(foundRemove).to.equal(true)
        end)

        it("should detect className changes between versions", function()
            local packageId = _generatePackageId()

            local v1 = _makeSimpleTree()
            _publishVersion(packageId, "DiffClassTest", v1, 1)

            local v2 = TreeUtils.deepClone(v1)
            v2.Health = {
                ["$className"] = "StringValue",
                ["$properties"] = { Value = "full" },
            }
            _publishVersion(packageId, "DiffClassTest", v2, 2)

            local ops = TreeDiff.diff(_fetchVersionTree(packageId, 1), _fetchVersionTree(packageId, 2))

            local foundRemove = false
            local foundAdd = false
            for _, op in ops do
                if op.Path[1] == "Health" then
                    if op.Kind == "Remove" then
                        foundRemove = true
                    end
                    if op.Kind == "Add" then
                        foundAdd = true
                    end
                end
            end
            expect(foundRemove).to.equal(true)
            expect(foundAdd).to.equal(true)
        end)
    end)

    describe("three-way merge with registry", function()
        it("should merge local and remote changes without conflicts", function()
            local packageId = _generatePackageId()

            local base = _makeSimpleTree()
            _publishVersion(packageId, "MergeNoConflict", base, 1)
            local fetchedBase = _fetchVersionTree(packageId, 1)

            local localTree = TreeUtils.deepClone(fetchedBase)
            localTree.Health["$properties"].Value = 500

            local remoteTree = TreeUtils.deepClone(fetchedBase)
            remoteTree.Label["$properties"].Value = "world"
            _publishVersion(packageId, "MergeNoConflict", remoteTree, 2)

            local result = Merger.merge(fetchedBase, localTree, _fetchVersionTree(packageId, 2))
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.Health["$properties"].Value).to.equal(500)
            expect(result.Tree.Label["$properties"].Value).to.equal("world")
        end)

        it("should detect conflicts from divergent changes", function()
            local packageId = _generatePackageId()

            local base = _makeSimpleTree()
            _publishVersion(packageId, "MergeConflict", base, 1)
            local fetchedBase = _fetchVersionTree(packageId, 1)

            local localTree = TreeUtils.deepClone(fetchedBase)
            localTree.Health["$properties"].Value = 300

            local remoteTree = TreeUtils.deepClone(fetchedBase)
            remoteTree.Health["$properties"].Value = 700
            _publishVersion(packageId, "MergeConflict", remoteTree, 2)

            local result = Merger.merge(fetchedBase, localTree, _fetchVersionTree(packageId, 2))
            expect(#result.Conflicts > 0).to.equal(true)
            expect(result.Tree.Health["$properties"].Value).to.equal(300)
        end)

        it("should merge child additions from both sides", function()
            local packageId = _generatePackageId()

            local base = _makeSimpleTree()
            _publishVersion(packageId, "MergeBothAdd", base, 1)
            local fetchedBase = _fetchVersionTree(packageId, 1)

            local localTree = TreeUtils.deepClone(fetchedBase)
            localTree.LocalChild = {
                ["$className"] = "BoolValue",
                ["$properties"] = { Value = true },
            }

            local remoteTree = TreeUtils.deepClone(fetchedBase)
            remoteTree.RemoteChild = {
                ["$className"] = "StringValue",
                ["$properties"] = { Value = "remote" },
            }
            _publishVersion(packageId, "MergeBothAdd", remoteTree, 2)

            local result = Merger.merge(fetchedBase, localTree, _fetchVersionTree(packageId, 2))
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.LocalChild).to.be.ok()
            expect(result.Tree.RemoteChild).to.be.ok()
        end)

        it("should merge and re-publish the result", function()
            local packageId = _generatePackageId()

            local base = _makeSimpleTree()
            _publishVersion(packageId, "MergeRepublish", base, 1)
            local fetchedBase = _fetchVersionTree(packageId, 1)

            local localTree = TreeUtils.deepClone(fetchedBase)
            localTree.Health["$properties"].Value = 250

            local remoteTree = TreeUtils.deepClone(fetchedBase)
            remoteTree.Label["$properties"].Value = "merged"
            _publishVersion(packageId, "MergeRepublish", remoteTree, 2)

            local mergeResult = Merger.merge(fetchedBase, localTree, _fetchVersionTree(packageId, 2))
            expect(#mergeResult.Conflicts).to.equal(0)

            _publishVersion(packageId, "MergeRepublish", mergeResult.Tree, 3)

            local metadata = _fetchMetadata(packageId)
            expect(metadata.latestVersion).to.equal(3)

            local fetched3 = _fetchVersionTree(packageId, 3)
            expect(fetched3.Health["$properties"].Value).to.equal(250)
            expect(fetched3.Label["$properties"].Value).to.equal("merged")
        end)
    end)

    describe("round-trip via registry", function()
        it("should round-trip a complex tree", function()
            local packageId = _generatePackageId()

            local original = _makeComplexTree()
            _publishVersion(packageId, "RoundTripComplex", original, 1)

            local fetched = _fetchVersionTree(packageId, 1)
            expect(TreeUtils.deepEqual(original, fetched)).to.equal(true)
        end)

        it("should round-trip a tree with attributes", function()
            local packageId = _generatePackageId()

            local original = _makeTreeWithAttributes()
            _publishVersion(packageId, "RoundTripAttrs", original, 1)

            local fetched = _fetchVersionTree(packageId, 1)
            expect(TreeUtils.deepEqual(original, fetched)).to.equal(true)
        end)

        it("should round-trip updated versions", function()
            local packageId = _generatePackageId()

            local v1 = _makeComplexTree()
            _publishVersion(packageId, "RoundTripVersions", v1, 1)

            local v2 = TreeUtils.deepClone(v1)
            v2.Config.MaxHealth["$properties"].Value = 200
            v2.Config.Settings.Debug["$properties"].Value = true
            v2.Handler["$properties"].Source = "return { version = 2 }"
            _publishVersion(packageId, "RoundTripVersions", v2, 2)

            expect(TreeUtils.deepEqual(v1, _fetchVersionTree(packageId, 1))).to.equal(true)
            expect(TreeUtils.deepEqual(v2, _fetchVersionTree(packageId, 2))).to.equal(true)
        end)
    end)

    describe("edge cases", function()
        it("should handle a leaf-only package", function()
            local packageId = _generatePackageId()

            local tree = {
                ["$className"] = "ModuleScript",
                ["$properties"] = { Source = 'return "hello"' },
            }
            _publishVersion(packageId, "LeafOnly", tree, 1)

            local fetched = _fetchVersionTree(packageId, 1)
            expect(fetched["$className"]).to.equal("ModuleScript")
            expect(fetched["$properties"].Source).to.equal('return "hello"')
        end)

        it("should handle deeply nested trees", function()
            local packageId = _generatePackageId()

            local tree = {
                ["$className"] = "Folder",
                Level1 = {
                    ["$className"] = "Folder",
                    Level2 = {
                        ["$className"] = "Folder",
                        Level3 = {
                            ["$className"] = "Folder",
                            Level4 = {
                                ["$className"] = "Folder",
                                DeepValue = {
                                    ["$className"] = "NumberValue",
                                    ["$properties"] = { Value = 12345 },
                                },
                            },
                        },
                    },
                },
            }
            _publishVersion(packageId, "DeepNest", tree, 1)

            local fetched = _fetchVersionTree(packageId, 1)
            expect(TreeUtils.deepEqual(tree, fetched)).to.equal(true)
        end)

        it("should handle many siblings", function()
            local packageId = _generatePackageId()

            local tree: { [string]: any } = { ["$className"] = "Folder" }
            for i = 1, 15 do
                tree[`Item{i}`] = {
                    ["$className"] = "NumberValue",
                    ["$properties"] = { Value = i * 10 },
                }
            end
            _publishVersion(packageId, "ManySiblings", tree, 1)

            local fetched = _fetchVersionTree(packageId, 1)
            expect(fetched.Item1["$properties"].Value).to.equal(10)
            expect(fetched.Item8["$properties"].Value).to.equal(80)
            expect(fetched.Item15["$properties"].Value).to.equal(150)
        end)

        it("should handle special characters in string properties", function()
            local packageId = _generatePackageId()

            local tree = {
                ["$className"] = "Folder",
                Script = {
                    ["$className"] = "ModuleScript",
                    ["$properties"] = {
                        Source = 'local x = "hello\\nworld"\nreturn x .. "tab\\there"',
                    },
                },
                Label = {
                    ["$className"] = "StringValue",
                    ["$properties"] = {
                        Value = "quotes \"inside\" and 'single' too",
                    },
                },
            }
            _publishVersion(packageId, "SpecialChars", tree, 1)

            local fetched = _fetchVersionTree(packageId, 1)
            expect(fetched.Script["$properties"].Source).to.equal(tree.Script["$properties"].Source)
            expect(fetched.Label["$properties"].Value).to.equal(tree.Label["$properties"].Value)
        end)

        it("should reject duplicate version numbers", function()
            local packageId = _generatePackageId()

            local tree = _makeSimpleTree()
            _publishVersion(packageId, "DuplicateTest", tree, 1)

            local response = _request("PUT", `/packages/{packageId}/versions/1`, serde.encode("json", tree), {
                ["X-Package-Name"] = "DuplicateTest",
            })
            expect(response.statusCode).to.equal(409)
        end)
    end)

    afterAll(function()
        _cleanupTestPackages()
    end)
end
