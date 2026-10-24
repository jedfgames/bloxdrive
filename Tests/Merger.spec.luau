--[[

Merger.spec

Tests for the Merger module. These tests use pure TreeNode tables and do
not require any Roblox APIs.

--]]

const Merger = require("@bloxdrive/Merger")

return function()
    describe("merge", function()
        it("should produce the base tree when no changes are made", function()
            const base = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
                Child = {
                    ["$className"] = "Part",
                },
            }

            const result = Merger.merge(base, base, base)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$properties"].Value).to.equal(10)
            expect(result.Tree.Child).to.be.ok()
        end)

        it("should accept local-only property changes", function()
            const base = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
            }
            const local_ = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 20 },
            }

            const result = Merger.merge(base, local_, base)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$properties"].Value).to.equal(20)
        end)

        it("should accept remote-only property changes", function()
            const base = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
            }
            const remote = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 30 },
            }

            const result = Merger.merge(base, base, remote)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$properties"].Value).to.equal(30)
        end)

        it("should merge non-overlapping changes from both sides", function()
            const base = {
                ["$className"] = "Folder",
                ["$properties"] = { A = 1, B = 2 },
            }
            const local_ = {
                ["$className"] = "Folder",
                ["$properties"] = { A = 10, B = 2 },
            }
            const remote = {
                ["$className"] = "Folder",
                ["$properties"] = { A = 1, B = 20 },
            }

            const result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$properties"].A).to.equal(10)
            expect(result.Tree["$properties"].B).to.equal(20)
        end)

        it("should detect conflicts when both sides change the same property", function()
            const base = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
            }
            const local_ = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 20 },
            }
            const remote = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 30 },
            }

            const result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(1)
            expect(result.Conflicts[1].LocalValue).to.equal(20)
            expect(result.Conflicts[1].RemoteValue).to.equal(30)
            -- Local wins by default
            expect(result.Tree["$properties"].Value).to.equal(20)
        end)

        it("should not conflict when both sides make the same change", function()
            const base = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
            }
            const changed = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 20 },
            }

            const result = Merger.merge(base, changed, changed)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$properties"].Value).to.equal(20)
        end)

        it("should accept local-only child additions", function()
            const base = {
                ["$className"] = "Folder",
            }
            const local_ = {
                ["$className"] = "Folder",
                NewChild = {
                    ["$className"] = "Part",
                },
            }

            const result = Merger.merge(base, local_, base)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.NewChild).to.be.ok()
            expect(result.Tree.NewChild["$className"]).to.equal("Part")
        end)

        it("should accept remote-only child additions", function()
            const base = {
                ["$className"] = "Folder",
            }
            const remote = {
                ["$className"] = "Folder",
                NewChild = {
                    ["$className"] = "Part",
                },
            }

            const result = Merger.merge(base, base, remote)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.NewChild).to.be.ok()
        end)

        it("should accept local-only child deletions", function()
            const base = {
                ["$className"] = "Folder",
                OldChild = {
                    ["$className"] = "Part",
                },
            }
            const local_ = {
                ["$className"] = "Folder",
            }

            const result = Merger.merge(base, local_, base)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.OldChild).to.equal(nil)
        end)

        it("should create orphan when local deletes but remote modifies", function()
            const base = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = false },
                },
            }
            const local_ = {
                ["$className"] = "Folder",
            }
            const remote = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = true },
                },
            }

            const result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(1)
            expect(result.Tree.Child).to.equal(nil)
            expect(result.Tree.Child_ORPHANED).to.be.ok()
            expect(result.Tree.Child_ORPHANED["$className"]).to.equal("Part")
        end)

        it("should create orphan when remote deletes but local modifies", function()
            const base = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = false },
                },
            }
            const local_ = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = true },
                },
            }
            const remote = {
                ["$className"] = "Folder",
            }

            const result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(1)
            expect(result.Tree.Child).to.equal(nil)
            expect(result.Tree.Child_ORPHANED).to.be.ok()
        end)

        it("should handle both sides deleting the same child", function()
            const base = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                },
            }
            const deleted = {
                ["$className"] = "Folder",
            }

            const result = Merger.merge(base, deleted, deleted)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.Child).to.equal(nil)
        end)

        it("should merge attribute changes independently", function()
            const base = {
                ["$className"] = "Folder",
                ["$attributes"] = { A = 1, B = 2 },
            }
            const local_ = {
                ["$className"] = "Folder",
                ["$attributes"] = { A = 10, B = 2 },
            }
            const remote = {
                ["$className"] = "Folder",
                ["$attributes"] = { A = 1, B = 20 },
            }

            const result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$attributes"].A).to.equal(10)
            expect(result.Tree["$attributes"].B).to.equal(20)
        end)

        it("should merge additions from both sides in different subtrees", function()
            const base = {
                ["$className"] = "Folder",
            }
            const local_ = {
                ["$className"] = "Folder",
                LocalChild = {
                    ["$className"] = "Part",
                },
            }
            const remote = {
                ["$className"] = "Folder",
                RemoteChild = {
                    ["$className"] = "MeshPart",
                },
            }

            const result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.LocalChild).to.be.ok()
            expect(result.Tree.RemoteChild).to.be.ok()
        end)
    end)
end
