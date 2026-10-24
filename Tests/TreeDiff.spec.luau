--[[

TreeDiff.spec

Tests for the TreeDiff module. These tests use pure TreeNode tables and do
not require any Roblox APIs.

--]]

const TreeDiff = require("@bloxdrive/TreeDiff")

return function()
    describe("diff", function()
        it("should return no operations for identical trees", function()
            const tree = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = true },
                },
            }

            const ops = TreeDiff.diff(tree, tree)
            expect(#ops).to.equal(0)
        end)

        it("should detect added children", function()
            const oldTree = {
                ["$className"] = "Folder",
            }
            const newTree = {
                ["$className"] = "Folder",
                NewChild = {
                    ["$className"] = "Part",
                },
            }

            const ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Add")
            expect(ops[1].Path[1]).to.equal("NewChild")
        end)

        it("should detect removed children", function()
            const oldTree = {
                ["$className"] = "Folder",
                OldChild = {
                    ["$className"] = "Part",
                },
            }
            const newTree = {
                ["$className"] = "Folder",
            }

            const ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Remove")
            expect(ops[1].Path[1]).to.equal("OldChild")
        end)

        it("should detect modified properties", function()
            const oldTree = {
                ["$className"] = "Part",
                ["$properties"] = { Anchored = true },
            }
            const newTree = {
                ["$className"] = "Part",
                ["$properties"] = { Anchored = false },
            }

            const ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Modify")
            expect(ops[1].Path[1]).to.equal("$properties")
            expect(ops[1].Path[2]).to.equal("Anchored")
            expect(ops[1].OldValue).to.equal(true)
            expect(ops[1].NewValue).to.equal(false)
        end)

        it("should detect added properties", function()
            const oldTree = {
                ["$className"] = "Part",
                ["$properties"] = {},
            }
            const newTree = {
                ["$className"] = "Part",
                ["$properties"] = { Anchored = true },
            }

            const ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Add")
            expect(ops[1].Path[2]).to.equal("Anchored")
        end)

        it("should detect removed properties", function()
            const oldTree = {
                ["$className"] = "Part",
                ["$properties"] = { Anchored = true },
            }
            const newTree = {
                ["$className"] = "Part",
                ["$properties"] = {},
            }

            const ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Remove")
            expect(ops[1].Path[2]).to.equal("Anchored")
        end)

        it("should detect modified attributes", function()
            const oldTree = {
                ["$className"] = "Folder",
                ["$attributes"] = { Score = 10 },
            }
            const newTree = {
                ["$className"] = "Folder",
                ["$attributes"] = { Score = 20 },
            }

            const ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Kind).to.equal("Modify")
            expect(ops[1].Path[1]).to.equal("$attributes")
            expect(ops[1].Path[2]).to.equal("Score")
        end)

        it("should detect className changes as remove + add", function()
            const oldTree = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                },
            }
            const newTree = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "MeshPart",
                },
            }

            const ops = TreeDiff.diff(oldTree, newTree)
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
            const oldTree = {
                ["$className"] = "Folder",
                A = {
                    ["$className"] = "Folder",
                    B = {
                        ["$className"] = "Part",
                        ["$properties"] = { Anchored = true },
                    },
                },
            }
            const newTree = {
                ["$className"] = "Folder",
                A = {
                    ["$className"] = "Folder",
                    B = {
                        ["$className"] = "Part",
                        ["$properties"] = { Anchored = false },
                    },
                },
            }

            const ops = TreeDiff.diff(oldTree, newTree)
            expect(#ops).to.equal(1)
            expect(ops[1].Path[1]).to.equal("A")
            expect(ops[1].Path[2]).to.equal("B")
            expect(ops[1].Path[3]).to.equal("$properties")
            expect(ops[1].Path[4]).to.equal("Anchored")
        end)
    end)
end
