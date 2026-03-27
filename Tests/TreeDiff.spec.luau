--[[

TreeDiff

Tests for the TreeDiff module. These tests use pure TreeNode tables and do
not require any Roblox APIs.

--]]

local TreeDiff = require("@bloxdrive/TreeDiff")

return function()
    describe("diff", function()
        it("should return no operations for identical trees", function()
            local tree = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = true },
                },
            }

            local ops = TreeDiff.diff(tree, tree)
            expect(#ops).to.equal(0)
        end)

        it("should detect added children", function()
            local oldTree = {
                ["$className"] = "Folder",
            }
            local newTree = {
                ["$className"] = "Folder",
                NewChild = {
                    ["$className"] = "Part",
                },
            }

            local ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Add")
            expect(ops[1].Path[1]).to.equal("NewChild")
        end)

        it("should detect removed children", function()
            local oldTree = {
                ["$className"] = "Folder",
                OldChild = {
                    ["$className"] = "Part",
                },
            }
            local newTree = {
                ["$className"] = "Folder",
            }

            local ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Remove")
            expect(ops[1].Path[1]).to.equal("OldChild")
        end)

        it("should detect modified properties", function()
            local oldTree = {
                ["$className"] = "Part",
                ["$properties"] = { Anchored = true },
            }
            local newTree = {
                ["$className"] = "Part",
                ["$properties"] = { Anchored = false },
            }

            local ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Modify")
            expect(ops[1].Path[1]).to.equal("$properties")
            expect(ops[1].Path[2]).to.equal("Anchored")
            expect(ops[1].OldValue).to.equal(true)
            expect(ops[1].NewValue).to.equal(false)
        end)

        it("should detect added properties", function()
            local oldTree = {
                ["$className"] = "Part",
                ["$properties"] = {},
            }
            local newTree = {
                ["$className"] = "Part",
                ["$properties"] = { Anchored = true },
            }

            local ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Add")
            expect(ops[1].Path[2]).to.equal("Anchored")
        end)

        it("should detect removed properties", function()
            local oldTree = {
                ["$className"] = "Part",
                ["$properties"] = { Anchored = true },
            }
            local newTree = {
                ["$className"] = "Part",
                ["$properties"] = {},
            }

            local ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Remove")
            expect(ops[1].Path[2]).to.equal("Anchored")
        end)

        it("should detect modified attributes", function()
            local oldTree = {
                ["$className"] = "Folder",
                ["$attributes"] = { Score = 10 },
            }
            local newTree = {
                ["$className"] = "Folder",
                ["$attributes"] = { Score = 20 },
            }

            local ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Modify")
            expect(ops[1].Path[1]).to.equal("$attributes")
            expect(ops[1].Path[2]).to.equal("Score")
        end)

        it("should detect className changes as remove + add", function()
            local oldTree = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                },
            }
            local newTree = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "MeshPart",
                },
            }

            local ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(2)

            local removeOp, addOp
            for _, op in ops do
                if op.Kind == "Remove" then
                    removeOp = op
                elseif op.Kind == "Add" then
                    addOp = op
                end
            end

            expect(removeOp).to.be.ok()
            expect(addOp).to.be.ok()
            expect(removeOp.Path[1]).to.equal("Child")
            expect(addOp.Path[1]).to.equal("Child")
        end)

        it("should handle deeply nested changes", function()
            local oldTree = {
                ["$className"] = "Folder",
                A = {
                    ["$className"] = "Folder",
                    B = {
                        ["$className"] = "Part",
                        ["$properties"] = { Anchored = true },
                    },
                },
            }
            local newTree = {
                ["$className"] = "Folder",
                A = {
                    ["$className"] = "Folder",
                    B = {
                        ["$className"] = "Part",
                        ["$properties"] = { Anchored = false },
                    },
                },
            }

            local ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Path[1]).to.equal("A")
            expect(ops[1].Path[2]).to.equal("B")
            expect(ops[1].Path[3]).to.equal("$properties")
            expect(ops[1].Path[4]).to.equal("Anchored")
        end)
    end)
end
