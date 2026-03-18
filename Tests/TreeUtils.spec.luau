--[[

TreeUtils

Tests for the TreeUtils module. These tests use pure tables and do not
require any Roblox APIs.

--]]

local TreeUtils = require("@rbxpackageloader/TreeUtils")

return function()
    describe("isMetadataKey", function()
        it("should return true for $className", function()
            expect(TreeUtils.isMetadataKey("$className")).to.equal(true)
        end)

        it("should return true for $properties", function()
            expect(TreeUtils.isMetadataKey("$properties")).to.equal(true)
        end)

        it("should return true for $attributes", function()
            expect(TreeUtils.isMetadataKey("$attributes")).to.equal(true)
        end)

        it("should return false for regular keys", function()
            expect(TreeUtils.isMetadataKey("Child")).to.equal(false)
            expect(TreeUtils.isMetadataKey("Folder")).to.equal(false)
            expect(TreeUtils.isMetadataKey("Part")).to.equal(false)
        end)
    end)

    describe("getChildKeys", function()
        it("should return child keys with $className", function()
            local node = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
                Child = {
                    ["$className"] = "Part",
                },
            }

            local children = TreeUtils.getChildKeys(node)
            expect(children.Child).to.equal(true)
            expect(children["$className"]).to.equal(nil)
            expect(children["$properties"]).to.equal(nil)
        end)

        it("should skip non-table values", function()
            local node = {
                ["$className"] = "Folder",
                SomeString = "hello",
                Child = {
                    ["$className"] = "Part",
                },
            }

            local children = TreeUtils.getChildKeys(node)
            expect(children.Child).to.equal(true)
            expect(children.SomeString).to.equal(nil)
        end)

        it("should skip tables without $className", function()
            local node = {
                ["$className"] = "Folder",
                NotAChild = { key = "value" },
                Child = {
                    ["$className"] = "Part",
                },
            }

            local children = TreeUtils.getChildKeys(node)
            expect(children.Child).to.equal(true)
            expect(children.NotAChild).to.equal(nil)
        end)

        it("should return empty for a leaf node", function()
            local node = {
                ["$className"] = "Part",
                ["$properties"] = { Anchored = true },
            }

            local children = TreeUtils.getChildKeys(node)
            expect(next(children)).to.equal(nil)
        end)
    end)

    describe("deepEqual", function()
        it("should return true for equal primitives", function()
            expect(TreeUtils.deepEqual(1, 1)).to.equal(true)
            expect(TreeUtils.deepEqual("hello", "hello")).to.equal(true)
            expect(TreeUtils.deepEqual(true, true)).to.equal(true)
        end)

        it("should return false for different primitives", function()
            expect(TreeUtils.deepEqual(1, 2)).to.equal(false)
            expect(TreeUtils.deepEqual("a", "b")).to.equal(false)
            expect(TreeUtils.deepEqual(true, false)).to.equal(false)
        end)

        it("should return false for different types", function()
            expect(TreeUtils.deepEqual(1, "1")).to.equal(false)
            expect(TreeUtils.deepEqual(true, 1)).to.equal(false)
        end)

        it("should return true for equal flat tables", function()
            expect(TreeUtils.deepEqual({ a = 1, b = 2 }, { a = 1, b = 2 })).to.equal(true)
        end)

        it("should return false when keys differ", function()
            expect(TreeUtils.deepEqual({ a = 1 }, { a = 1, b = 2 })).to.equal(false)
            expect(TreeUtils.deepEqual({ a = 1, b = 2 }, { a = 1 })).to.equal(false)
        end)

        it("should compare nested tables", function()
            local a = { x = { y = { z = 1 } } }
            local b = { x = { y = { z = 1 } } }
            local c = { x = { y = { z = 2 } } }

            expect(TreeUtils.deepEqual(a, b)).to.equal(true)
            expect(TreeUtils.deepEqual(a, c)).to.equal(false)
        end)

        it("should compare arrays", function()
            expect(TreeUtils.deepEqual({ 1, 2, 3 }, { 1, 2, 3 })).to.equal(true)
            expect(TreeUtils.deepEqual({ 1, 2, 3 }, { 1, 2, 4 })).to.equal(false)
            expect(TreeUtils.deepEqual({ 1, 2 }, { 1, 2, 3 })).to.equal(false)
        end)
    end)

    describe("deepClone", function()
        it("should return primitives as-is", function()
            expect(TreeUtils.deepClone(42)).to.equal(42)
            expect(TreeUtils.deepClone("hello")).to.equal("hello")
            expect(TreeUtils.deepClone(true)).to.equal(true)
        end)

        it("should clone a flat table", function()
            local original = { a = 1, b = 2 }
            local cloned = TreeUtils.deepClone(original)

            expect(cloned.a).to.equal(1)
            expect(cloned.b).to.equal(2)
            expect(cloned).to.never.equal(original)
        end)

        it("should deep clone nested tables", function()
            local original = { x = { y = 1 } }
            local cloned = TreeUtils.deepClone(original)

            expect(cloned.x.y).to.equal(1)
            expect(cloned.x).to.never.equal(original.x)
        end)

        it("should not share references with the original", function()
            local original = { items = { 1, 2, 3 } }
            local cloned = TreeUtils.deepClone(original)

            table.insert(cloned.items, 4)
            expect(#original.items).to.equal(3)
            expect(#cloned.items).to.equal(4)
        end)
    end)
end
