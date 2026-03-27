--[[

Serializer

Tests for the Serializer module. These tests use Lune's roblox library
to create real Instance objects for serialization testing.

--]]

local roblox = require("@lune/roblox")
local Instance = roblox.Instance

local PropertyReflection = require("@bloxdrive/PropertyReflection")
local Serializer = require("@bloxdrive/Serializer")
local _TreeUtils = require("@bloxdrive/TreeUtils")

-- Set up a mock PropertyReflection provider for Lune since
-- ReflectionService is not available
local function setupMockProvider()
    local provider = {}

    function provider.GetSerializableProperties(_self: any, _className: string)
        -- Return empty for tests that don't need properties
        return {}
    end

    PropertyReflection.setProvider(provider)
end

return function()
    setupMockProvider()

    describe("serialize", function()
        it("should serialize a simple folder", function()
            local folder = Instance.new("Folder")
            folder.Name = "TestFolder"

            local tree = Serializer.serialize(folder)
            expect(tree["$className"]).to.equal("Folder")
        end)

        it("should serialize children keyed by name", function()
            local folder = Instance.new("Folder")
            folder.Name = "Root"

            local child1 = Instance.new("Folder")
            child1.Name = "ChildA"
            child1.Parent = folder

            local child2 = Instance.new("Folder")
            child2.Name = "ChildB"
            child2.Parent = folder

            local tree = Serializer.serialize(folder)
            expect(tree.ChildA).to.be.ok()
            expect(tree.ChildA["$className"]).to.equal("Folder")
            expect(tree.ChildB).to.be.ok()
            expect(tree.ChildB["$className"]).to.equal("Folder")
        end)

        it("should skip .bloxdrive markers", function()
            local folder = Instance.new("Folder")
            folder.Name = "Root"

            local marker = Instance.new("StringValue")
            marker.Name = ".bloxdrive"
            marker.Value = '{"Id":"test"}'
            marker.Parent = folder

            local child = Instance.new("Folder")
            child.Name = "RealChild"
            child.Parent = folder

            local tree = Serializer.serialize(folder)
            expect(tree[".bloxdrive"]).to.equal(nil)
            expect(tree.RealChild).to.be.ok()
        end)

        it("should handle duplicate child names with auto-increment", function()
            local folder = Instance.new("Folder")
            folder.Name = "Root"

            local child1 = Instance.new("Folder")
            child1.Name = "Part"
            child1.Parent = folder

            local child2 = Instance.new("Folder")
            child2.Name = "Part"
            child2.Parent = folder

            local child3 = Instance.new("Folder")
            child3.Name = "Part"
            child3.Parent = folder

            local tree = Serializer.serialize(folder)
            expect(tree.Part).to.be.ok()
            expect(tree.Part1).to.be.ok()
            expect(tree.Part2).to.be.ok()
        end)

        it("should escape metadata-like child names", function()
            local folder = Instance.new("Folder")
            folder.Name = "Root"

            local child = Instance.new("Folder")
            child.Name = "$className"
            child.Parent = folder

            local tree = Serializer.serialize(folder)
            -- Should be escaped with underscore prefix
            expect(tree["_$className"]).to.be.ok()
            expect(tree["_$className"]["$className"]).to.equal("Folder")
        end)

        it("should serialize nested hierarchies", function()
            local root = Instance.new("Folder")
            root.Name = "Root"

            local parent = Instance.new("Folder")
            parent.Name = "Parent"
            parent.Parent = root

            local child = Instance.new("Folder")
            child.Name = "Child"
            child.Parent = parent

            local tree = Serializer.serialize(root)
            expect(tree.Parent).to.be.ok()
            expect(tree.Parent.Child).to.be.ok()
            expect(tree.Parent.Child["$className"]).to.equal("Folder")
        end)
    end)

    describe("serializeToFiles", function()
        it("should create instance.json for root", function()
            local tree = {
                ["$className"] = "Folder",
            }

            local result = Serializer.serializeToFiles(tree)
            expect(result.Files["instance.json"]).to.be.ok()
            expect(result.Files["instance.json"]["$className"]).to.equal("Folder")
        end)

        it("should create .json files for leaf children", function()
            local tree = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = true },
                },
            }

            local result = Serializer.serializeToFiles(tree)
            expect(result.Files["Child.json"]).to.be.ok()
            expect(result.Files["Child.json"]["$className"]).to.equal("Part")
        end)

        it("should create directories for container children", function()
            local tree = {
                ["$className"] = "Folder",
                Container = {
                    ["$className"] = "Folder",
                    Inner = {
                        ["$className"] = "Part",
                    },
                },
            }

            local result = Serializer.serializeToFiles(tree)
            expect(result.Files["Container/instance.json"]).to.be.ok()
            expect(result.Files["Container/Inner.json"]).to.be.ok()
        end)

        it("should include all paths in manifest", function()
            local tree = {
                ["$className"] = "Folder",
                Leaf = {
                    ["$className"] = "Part",
                },
            }

            local result = Serializer.serializeToFiles(tree)
            expect(#result.Manifest).to.equal(2)

            local hasRoot = false
            local hasLeaf = false
            for _, path in result.Manifest do
                if path == "instance.json" then
                    hasRoot = true
                end
                if path == "Leaf.json" then
                    hasLeaf = true
                end
            end
            expect(hasRoot).to.equal(true)
            expect(hasLeaf).to.equal(true)
        end)
    end)
end
