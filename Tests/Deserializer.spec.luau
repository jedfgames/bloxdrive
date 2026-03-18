--[[

Deserializer

Tests for the Deserializer module. Tests cover both tree-to-instance
deserialization and the reassembleTree file-to-tree reconstruction.

--]]

local Deserializer = require("@rbxpackageloader/Deserializer")

return function()
    describe("reassembleTree", function()
        it("should reassemble a root-only tree", function()
            local files = {
                ["instance.json"] = {
                    ["$className"] = "Folder",
                    ["$properties"] = { Value = 10 },
                },
            }

            local tree = Deserializer.reassembleTree(files)
            expect(tree["$className"]).to.equal("Folder")
            expect(tree["$properties"].Value).to.equal(10)
        end)

        it("should reassemble leaf children from .json files", function()
            local files = {
                ["instance.json"] = { ["$className"] = "Folder" },
                ["Child.json"] = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = true },
                },
            }

            local tree = Deserializer.reassembleTree(files)
            expect(tree.Child).to.be.ok()
            expect(tree.Child["$className"]).to.equal("Part")
            expect(tree.Child["$properties"].Anchored).to.equal(true)
        end)

        it("should reassemble container children from directories", function()
            local files = {
                ["instance.json"] = { ["$className"] = "Folder" },
                ["Container/instance.json"] = {
                    ["$className"] = "Folder",
                },
                ["Container/Inner.json"] = {
                    ["$className"] = "Part",
                },
            }

            local tree = Deserializer.reassembleTree(files)
            expect(tree.Container).to.be.ok()
            expect(tree.Container["$className"]).to.equal("Folder")
            expect(tree.Container.Inner).to.be.ok()
            expect(tree.Container.Inner["$className"]).to.equal("Part")
        end)

        it("should reassemble deeply nested structures", function()
            local files = {
                ["instance.json"] = { ["$className"] = "Folder" },
                ["A/instance.json"] = { ["$className"] = "Folder" },
                ["A/B/instance.json"] = { ["$className"] = "Folder" },
                ["A/B/Leaf.json"] = { ["$className"] = "Part" },
            }

            local tree = Deserializer.reassembleTree(files)
            expect(tree.A.B.Leaf).to.be.ok()
            expect(tree.A.B.Leaf["$className"]).to.equal("Part")
        end)

        it("should error when missing root instance.json", function()
            local files = {
                ["Child.json"] = { ["$className"] = "Part" },
            }

            expect(function()
                Deserializer.reassembleTree(files)
            end).to.throw()
        end)
    end)

    -- Note: deserialize() tests require the Roblox Instance.new
    -- global which is not available in Lune. These are covered by
    -- E2E tests in Studio instead.
end
