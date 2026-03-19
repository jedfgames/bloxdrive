--[[

Merger.spec

Tests for the Merger module. These tests use pure TreeNode tables and do
not require any Roblox APIs.

--]]

local Merger = require("@bloxdrive/Merger")

return function()
    describe("merge", function()
        it("should produce the base tree when no changes are made", function()
            local base = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
                Child = {
                    ["$className"] = "Part",
                },
            }

            local result = Merger.merge(base, base, base)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$properties"].Value).to.equal(10)
            expect(result.Tree.Child).to.be.ok()
        end)

        it("should accept local-only property changes", function()
            local base = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
            }
            local local_ = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 20 },
            }

            local result = Merger.merge(base, local_, base)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$properties"].Value).to.equal(20)
        end)

        it("should accept remote-only property changes", function()
            local base = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
            }
            local remote = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 30 },
            }

            local result = Merger.merge(base, base, remote)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$properties"].Value).to.equal(30)
        end)

        it("should merge non-overlapping changes from both sides", function()
            local base = {
                ["$className"] = "Folder",
                ["$properties"] = { A = 1, B = 2 },
            }
            local local_ = {
                ["$className"] = "Folder",
                ["$properties"] = { A = 10, B = 2 },
            }
            local remote = {
                ["$className"] = "Folder",
                ["$properties"] = { A = 1, B = 20 },
            }

            local result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$properties"].A).to.equal(10)
            expect(result.Tree["$properties"].B).to.equal(20)
        end)

        it("should detect conflicts when both sides change the same property", function()
            local base = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
            }
            local local_ = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 20 },
            }
            local remote = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 30 },
            }

            local result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(1)
            expect(result.Conflicts[1].LocalValue).to.equal(20)
            expect(result.Conflicts[1].RemoteValue).to.equal(30)
            -- Local wins by default
            expect(result.Tree["$properties"].Value).to.equal(20)
        end)

        it("should not conflict when both sides make the same change", function()
            local base = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 10 },
            }
            local changed = {
                ["$className"] = "Folder",
                ["$properties"] = { Value = 20 },
            }

            local result = Merger.merge(base, changed, changed)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$properties"].Value).to.equal(20)
        end)

        it("should accept local-only child additions", function()
            local base = {
                ["$className"] = "Folder",
            }
            local local_ = {
                ["$className"] = "Folder",
                NewChild = {
                    ["$className"] = "Part",
                },
            }

            local result = Merger.merge(base, local_, base)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.NewChild).to.be.ok()
            expect(result.Tree.NewChild["$className"]).to.equal("Part")
        end)

        it("should accept remote-only child additions", function()
            local base = {
                ["$className"] = "Folder",
            }
            local remote = {
                ["$className"] = "Folder",
                NewChild = {
                    ["$className"] = "Part",
                },
            }

            local result = Merger.merge(base, base, remote)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.NewChild).to.be.ok()
        end)

        it("should accept local-only child deletions", function()
            local base = {
                ["$className"] = "Folder",
                OldChild = {
                    ["$className"] = "Part",
                },
            }
            local local_ = {
                ["$className"] = "Folder",
            }

            local result = Merger.merge(base, local_, base)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.OldChild).to.equal(nil)
        end)

        it("should create orphan when local deletes but remote modifies", function()
            local base = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = false },
                },
            }
            local local_ = {
                ["$className"] = "Folder",
            }
            local remote = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = true },
                },
            }

            local result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(1)
            expect(result.Tree.Child).to.equal(nil)
            expect(result.Tree.Child_ORPHANED).to.be.ok()
            expect(result.Tree.Child_ORPHANED["$className"]).to.equal("Part")
        end)

        it("should create orphan when remote deletes but local modifies", function()
            local base = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = false },
                },
            }
            local local_ = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                    ["$properties"] = { Anchored = true },
                },
            }
            local remote = {
                ["$className"] = "Folder",
            }

            local result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(1)
            expect(result.Tree.Child).to.equal(nil)
            expect(result.Tree.Child_ORPHANED).to.be.ok()
        end)

        it("should handle both sides deleting the same child", function()
            local base = {
                ["$className"] = "Folder",
                Child = {
                    ["$className"] = "Part",
                },
            }
            local deleted = {
                ["$className"] = "Folder",
            }

            local result = Merger.merge(base, deleted, deleted)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.Child).to.equal(nil)
        end)

        it("should merge attribute changes independently", function()
            local base = {
                ["$className"] = "Folder",
                ["$attributes"] = { A = 1, B = 2 },
            }
            local local_ = {
                ["$className"] = "Folder",
                ["$attributes"] = { A = 10, B = 2 },
            }
            local remote = {
                ["$className"] = "Folder",
                ["$attributes"] = { A = 1, B = 20 },
            }

            local result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree["$attributes"].A).to.equal(10)
            expect(result.Tree["$attributes"].B).to.equal(20)
        end)

        it("should merge additions from both sides in different subtrees", function()
            local base = {
                ["$className"] = "Folder",
            }
            local local_ = {
                ["$className"] = "Folder",
                LocalChild = {
                    ["$className"] = "Part",
                },
            }
            local remote = {
                ["$className"] = "Folder",
                RemoteChild = {
                    ["$className"] = "MeshPart",
                },
            }

            local result = Merger.merge(base, local_, remote)
            expect(#result.Conflicts).to.equal(0)
            expect(result.Tree.LocalChild).to.be.ok()
            expect(result.Tree.RemoteChild).to.be.ok()
        end)
    end)
end
