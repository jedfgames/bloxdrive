--[[

RemoteTestScript

Test script that runs inside a real Roblox place via the Open Cloud Luau
Execution API. Exercises Serializer, Deserializer, PropertyReflection,
TreeDiff, Merger, Registry, and Bloxdrive.load with real instances.

The placeholder __REGISTRY_TOKEN__ is replaced at runtime by E2E.spec.luau
before submitting to the execution API.

--]]

local REGISTRY_TOKEN = __REGISTRY_TOKEN__

local ok, Bloxdrive = pcall(require, game.ReplicatedStorage.Source.Bloxdrive)
if not ok then
    print("[FAIL] Module load - " .. tostring(Bloxdrive))
    return { Passed = 0, Failed = 1, Success = false }
end

local Deserializer = Bloxdrive.Deserializer
local Merger = Bloxdrive.Merger
local PropertyReflection = Bloxdrive.PropertyReflection
local Serializer = Bloxdrive.Serializer
local TreeDiff = Bloxdrive.TreeDiff
local TreeUtils = Bloxdrive.TreeUtils

local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
    local success, err = pcall(fn)
    if success then
        passed += 1
        print("[PASS] " .. name)
    else
        failed += 1
        table.insert(errors, name .. ": " .. tostring(err))
        print("[FAIL] " .. name .. " - " .. tostring(err))
    end
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(
            (message or "Assertion failed")
                .. " (expected "
                .. tostring(expected)
                .. ", got "
                .. tostring(actual)
                .. ")"
        )
    end
end

----------------------------------------------
-- PropertyReflection tests
----------------------------------------------

test("PropertyReflection reads Part properties", function()
    local part = Instance.new("Part")
    part.Anchored = true
    part.Size = Vector3.new(4, 8, 2)
    part.Parent = workspace

    local props = PropertyReflection.getSerializableProperties(part)
    assertEqual(props.Anchored, true, "Anchored")

    assert(props.size ~= nil or props.Size ~= nil, "Size property not found")
    local sizeVal = props.size or props.Size
    assert(type(sizeVal) == "table", "Size should be a table")
    assert(sizeVal.Vector3 ~= nil, "Size should have Vector3 key")
    assertEqual(sizeVal.Vector3[1], 4, "Size X")
    assertEqual(sizeVal.Vector3[2], 8, "Size Y")
    assertEqual(sizeVal.Vector3[3], 2, "Size Z")

    part:Destroy()
end)

test("PropertyReflection sets Part properties", function()
    local part = Instance.new("Part")
    part.Parent = workspace

    PropertyReflection.setProperty(part, "Anchored", true)
    assertEqual(part.Anchored, true, "Anchored after set")

    PropertyReflection.setProperty(part, "size", { Vector3 = { 10, 20, 30 } })
    assertEqual(part.Size.X, 10, "Size X after set")
    assertEqual(part.Size.Y, 20, "Size Y after set")
    assertEqual(part.Size.Z, 30, "Size Z after set")

    part:Destroy()
end)

test("PropertyReflection handles Color3", function()
    local light = Instance.new("SpotLight")
    light.Color = Color3.new(1, 0, 0.5)
    light.Parent = workspace

    local props = PropertyReflection.getSerializableProperties(light)
    local color = props.Color or props.color
    assert(color ~= nil, "Color property not found")
    assert(type(color) == "table", "Color should be a table")
    assert(color.Color3 ~= nil, "Color should have Color3 key")

    light:Destroy()
end)

test("PropertyReflection handles CFrame", function()
    local part = Instance.new("Part")
    part.CFrame = CFrame.new(1, 2, 3)
    part.Parent = workspace

    local props = PropertyReflection.getSerializableProperties(part)
    local cf = props.CFrame
    assert(cf ~= nil, "CFrame property not found")
    assert(cf.CFrame ~= nil, "CFrame should have CFrame key")
    assertEqual(cf.CFrame.position[1], 1, "CFrame position X")

    part:Destroy()
end)

----------------------------------------------
-- Serializer round-trip tests
----------------------------------------------

test("Serialize and deserialize a simple folder", function()
    local folder = Instance.new("Folder")
    folder.Name = "TestPkg"
    folder.Parent = workspace

    local child1 = Instance.new("NumberValue")
    child1.Name = "Health"
    child1.Value = 100
    child1.Parent = folder

    local child2 = Instance.new("StringValue")
    child2.Name = "Label"
    child2.Value = "hello"
    child2.Parent = folder

    local tree = Serializer.serialize(folder)
    assertEqual(tree["$className"], "Folder")
    assert(tree.Health ~= nil, "Health child missing")
    assert(tree.Label ~= nil, "Label child missing")
    assertEqual(tree.Health["$className"], "NumberValue")
    assertEqual(tree.Label["$className"], "StringValue")

    folder:Destroy()
end)

test("Serialize skips .bloxdrive marker", function()
    local folder = Instance.new("Folder")
    folder.Name = "TestPkg"
    folder.Parent = workspace

    local marker = Instance.new("StringValue")
    marker.Name = ".bloxdrive"
    marker.Value = '{"Id":"test","Version":1}'
    marker.Parent = folder

    local child = Instance.new("Folder")
    child.Name = "Content"
    child.Parent = folder

    local tree = Serializer.serialize(folder)
    assertEqual(tree[".bloxdrive"], nil, "Marker should be skipped")
    assert(tree.Content ~= nil, "Content child should exist")

    folder:Destroy()
end)

test("Serialize handles duplicate child names", function()
    local folder = Instance.new("Folder")
    folder.Name = "TestPkg"
    folder.Parent = workspace

    local c1 = Instance.new("Part")
    c1.Name = "Block"
    c1.Parent = folder

    local c2 = Instance.new("Part")
    c2.Name = "Block"
    c2.Parent = folder

    local tree = Serializer.serialize(folder)
    assert(tree.Block ~= nil, "Block should exist")
    assert(tree.Block1 ~= nil, "Block1 should exist (auto-incremented)")

    local names = {}
    for _, child in folder:GetChildren() do
        table.insert(names, child.Name)
    end
    table.sort(names)
    assertEqual(names[1], "Block", "First child name")
    assertEqual(names[2], "Block1", "Second child name")

    folder:Destroy()
end)

test("Serialize round-trip preserves structure", function()
    local root = Instance.new("Folder")
    root.Name = "RoundTrip"
    root.Parent = workspace

    local sub = Instance.new("Folder")
    sub.Name = "SubFolder"
    sub.Parent = root

    local part = Instance.new("Part")
    part.Name = "MyPart"
    part.Anchored = true
    part.Size = Vector3.new(5, 10, 15)
    part.Parent = sub

    local tree1 = Serializer.serialize(root)

    local reconstructed = Instance.new("Folder")
    reconstructed.Name = "Reconstructed"
    reconstructed.Parent = workspace

    for key, value in tree1 do
        if TreeUtils.isMetadataKey(key) then
            continue
        end
        if type(value) == "table" and value["$className"] then
            Deserializer.deserialize(key, value, reconstructed)
        end
    end

    local tree2 = Serializer.serialize(reconstructed)

    assert(tree2.SubFolder ~= nil, "SubFolder missing in round-trip")
    assert(tree2.SubFolder.MyPart ~= nil, "MyPart missing in round-trip")
    assertEqual(tree2.SubFolder.MyPart["$className"], "Part", "MyPart className")

    root:Destroy()
    reconstructed:Destroy()
end)

----------------------------------------------
-- TreeDiff tests with real instances
----------------------------------------------

test("TreeDiff detects property changes on real instances", function()
    local folder1 = Instance.new("Folder")
    folder1.Name = "Pkg"
    folder1.Parent = workspace

    local part1 = Instance.new("Part")
    part1.Name = "Block"
    part1.Anchored = true
    part1.Size = Vector3.new(4, 4, 4)
    part1.Parent = folder1

    local folder2 = Instance.new("Folder")
    folder2.Name = "Pkg"
    folder2.Parent = workspace

    local part2 = Instance.new("Part")
    part2.Name = "Block"
    part2.Anchored = true
    part2.Size = Vector3.new(4, 8, 4)
    part2.Parent = folder2

    local tree1 = Serializer.serialize(folder1)
    local tree2 = Serializer.serialize(folder2)

    local ops = TreeDiff.diff(tree1, tree2)
    assert(#ops > 0, "Should have diff operations for size change")

    local foundSize = false
    for _, op in ops do
        if op.Kind == "Modify" then
            local pathStr = table.concat(op.Path, ".")
            if string.find(pathStr, "size") or string.find(pathStr, "Size") then
                foundSize = true
            end
        end
    end
    assert(foundSize, "Should detect size change")

    folder1:Destroy()
    folder2:Destroy()
end)

----------------------------------------------
-- Three-way merge tests with real instances
----------------------------------------------

test("Three-way merge with real serialized trees", function()
    local base = Instance.new("Folder")
    base.Name = "MergeTest"
    base.Parent = workspace

    local health = Instance.new("NumberValue")
    health.Name = "Health"
    health.Value = 100
    health.Parent = base

    local speed = Instance.new("NumberValue")
    speed.Name = "Speed"
    speed.Value = 10
    speed.Parent = base

    local baseTree = Serializer.serialize(base)

    health.Value = 200
    local localTree = Serializer.serialize(base)

    health.Value = 100
    speed.Value = 20
    local remoteTree = Serializer.serialize(base)

    local result = Merger.merge(baseTree, localTree, remoteTree)
    assertEqual(#result.Conflicts, 0, "Should have no conflicts")

    local mergedHealth = result.Tree.Health["$properties"]
    local mergedSpeed = result.Tree.Speed["$properties"]

    local healthVal = mergedHealth.Value or mergedHealth.value
    local speedVal = mergedSpeed.Value or mergedSpeed.value
    assertEqual(healthVal, 200, "Health should be local's value")
    assertEqual(speedVal, 20, "Speed should be remote's value")

    base:Destroy()
end)

test("Three-way merge detects conflicts", function()
    local base = Instance.new("Folder")
    base.Name = "ConflictTest"
    base.Parent = workspace

    local val = Instance.new("NumberValue")
    val.Name = "Score"
    val.Value = 50
    val.Parent = base

    local baseTree = Serializer.serialize(base)

    val.Value = 100
    local localTree = Serializer.serialize(base)

    val.Value = 200
    local remoteTree = Serializer.serialize(base)

    val.Value = 50

    local result = Merger.merge(baseTree, localTree, remoteTree)
    assert(#result.Conflicts > 0, "Should have conflicts")

    local mergedScore = result.Tree.Score["$properties"]
    local scoreVal = mergedScore.Value or mergedScore.value
    assertEqual(scoreVal, 100, "Local should win conflicts")

    base:Destroy()
end)

----------------------------------------------
-- Surgical apply tests
----------------------------------------------

test("Surgical property update via TreeDiff", function()
    local folder = Instance.new("Folder")
    folder.Name = "SurgicalTest"
    folder.Parent = workspace

    local part = Instance.new("Part")
    part.Name = "Target"
    part.Anchored = true
    part.Size = Vector3.new(4, 4, 4)
    part.Parent = folder

    local currentTree = Serializer.serialize(folder)

    local targetTree = TreeUtils.deepClone(currentTree)
    targetTree.Target["$properties"].size = { Vector3 = { 4, 10, 4 } }

    local ops = TreeDiff.diff(currentTree, targetTree)
    assert(#ops > 0, "Should have diff ops")

    for _, op in ops do
        if op.Kind == "Modify" then
            local pathStr = table.concat(op.Path, ".")
            if string.find(pathStr, "size") or string.find(pathStr, "Size") then
                PropertyReflection.setProperty(part, "size", op.NewValue)
            end
        end
    end

    assertEqual(part.Size.Y, 10, "Size Y should be updated surgically")

    folder:Destroy()
end)

test("Surgical child addition via TreeDiff", function()
    local folder = Instance.new("Folder")
    folder.Name = "AddTest"
    folder.Parent = workspace

    local existing = Instance.new("NumberValue")
    existing.Name = "Existing"
    existing.Value = 42
    existing.Parent = folder

    local currentTree = Serializer.serialize(folder)

    local targetTree = TreeUtils.deepClone(currentTree)
    targetTree.NewChild = {
        ["$className"] = "StringValue",
        ["$properties"] = { Value = "hello" },
    }

    local ops = TreeDiff.diff(currentTree, targetTree)

    local addOps = {}
    for _, op in ops do
        if op.Kind == "Add" and op.Path[1] == "NewChild" then
            table.insert(addOps, op)
        end
    end
    assert(#addOps > 0, "Should have Add op for NewChild")

    Deserializer.deserialize("NewChild", addOps[1].Node, folder)

    local newChild = folder:FindFirstChild("NewChild")
    assert(newChild ~= nil, "NewChild should exist after surgical add")
    assertEqual(newChild.ClassName, "StringValue", "NewChild className")
    assertEqual(existing.Value, 42, "Existing value should be unchanged")

    folder:Destroy()
end)

test("Surgical child removal via TreeDiff", function()
    local folder = Instance.new("Folder")
    folder.Name = "RemoveTest"
    folder.Parent = workspace

    local keep = Instance.new("NumberValue")
    keep.Name = "Keep"
    keep.Value = 1
    keep.Parent = folder

    local remove = Instance.new("StringValue")
    remove.Name = "Remove"
    remove.Value = "bye"
    remove.Parent = folder

    local currentTree = Serializer.serialize(folder)

    local targetTree = TreeUtils.deepClone(currentTree)
    targetTree.Remove = nil

    local ops = TreeDiff.diff(currentTree, targetTree)

    for _, op in ops do
        if op.Kind == "Remove" and op.Path[1] == "Remove" then
            local child = folder:FindFirstChild("Remove")
            if child then
                child:Destroy()
            end
        end
    end

    assertEqual(folder:FindFirstChild("Remove"), nil, "Remove should be gone")
    assert(folder:FindFirstChild("Keep") ~= nil, "Keep should still exist")
    assertEqual(keep.Value, 1, "Keep value should be unchanged")

    folder:Destroy()
end)

----------------------------------------------
-- serializeToFiles / reassembleTree round-trip
----------------------------------------------

test("serializeToFiles and reassembleTree round-trip", function()
    local root = Instance.new("Folder")
    root.Name = "FilesTest"
    root.Parent = workspace

    local container = Instance.new("Folder")
    container.Name = "Models"
    container.Parent = root

    local leaf = Instance.new("Part")
    leaf.Name = "Block"
    leaf.Anchored = true
    leaf.Parent = container

    local topLeaf = Instance.new("NumberValue")
    topLeaf.Name = "Score"
    topLeaf.Value = 100
    topLeaf.Parent = root

    local tree = Serializer.serialize(root)
    local fileResult = Serializer.serializeToFiles(tree)

    assert(fileResult.Files["instance.json"] ~= nil, "Root instance.json")
    assert(fileResult.Files["Score.json"] ~= nil, "Score.json")
    assert(fileResult.Files["Models/instance.json"] ~= nil, "Models/instance.json")
    assert(fileResult.Files["Models/Block.json"] ~= nil, "Models/Block.json")

    local reassembled = Deserializer.reassembleTree(fileResult.Files)
    assertEqual(reassembled["$className"], "Folder", "Root className")
    assert(reassembled.Models ~= nil, "Models child")
    assert(reassembled.Models.Block ~= nil, "Block child")
    assert(reassembled.Score ~= nil, "Score child")

    root:Destroy()
end)

----------------------------------------------
-- Registry and load tests
----------------------------------------------

local REGISTRY_URL = "https://rbx-package-registry.batchprogrammer314.workers.dev"
local TEST_PACKAGE_ID = "e2e-remote-fixture"
local HttpService = game:GetService("HttpService")

if REGISTRY_TOKEN then
    -- Seed a test package for the registry and load tests
    local seedTree = {
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

    HttpService:RequestAsync({
        Url = REGISTRY_URL .. "/packages/" .. TEST_PACKAGE_ID .. "/versions/1",
        Method = "PUT",
        Headers = {
            Authorization = "Bearer " .. REGISTRY_TOKEN,
            ["Content-Type"] = "application/json",
            ["X-Package-Name"] = "E2EFixture",
        },
        Body = HttpService:JSONEncode(seedTree),
    })

    test("Registry fetches metadata", function()
        local Registry = Bloxdrive.Registry
        local registry = Registry.new({ RegistryKey = REGISTRY_TOKEN })

        local metadata = registry:FetchMetadata(TEST_PACKAGE_ID)
        assertEqual(metadata.Name, "E2EFixture", "Name should match")
        assertEqual(metadata.LatestVersion, 1, "LatestVersion should be 1")
    end)

    test("Registry fetches a specific version", function()
        local Registry = Bloxdrive.Registry
        local registry = Registry.new({ RegistryKey = REGISTRY_TOKEN })

        local tree = registry:FetchVersion(TEST_PACKAGE_ID, 1)
        assertEqual(tree["$className"], "Folder", "className should be Folder")
        assert(tree.Health ~= nil, "Health child should exist")
    end)

    test("Registry fetches latest version", function()
        local Registry = Bloxdrive.Registry
        local registry = Registry.new({ RegistryKey = REGISTRY_TOKEN })

        local tree, version = registry:FetchLatest(TEST_PACKAGE_ID)
        assertEqual(version, 1, "Latest version should be 1")
        assertEqual(tree["$className"], "Folder", "className should be Folder")
    end)

    Bloxdrive.configure({ RegistryKey = REGISTRY_TOKEN })

    test("load returns instance and result with Parent", function()
        local parent = Instance.new("Folder")
        parent.Name = "LoadTestParent"
        parent.Parent = workspace

        local instance, result = Bloxdrive.load(TEST_PACKAGE_ID, {
            Version = 1,
            Parent = parent,
        })

        assert(result.Success, "Load should succeed: " .. tostring(result.Error))
        assertEqual(result.PackageId, TEST_PACKAGE_ID, "PackageId should match")
        assert(instance ~= nil, "Instance should not be nil")
        assertEqual(instance, parent, "Instance should be the parent")

        parent:Destroy()
    end)

    test("load returns instance and result without Parent", function()
        local instance, result = Bloxdrive.load(TEST_PACKAGE_ID, {
            Version = 1,
        })

        assert(result.Success, "Load should succeed: " .. tostring(result.Error))
        assert(instance ~= nil, "Instance should not be nil")
        assertEqual(instance.Parent, nil, "Instance should not be parented")

        instance:Destroy()
    end)

    test("load returns nil instance on failure", function()
        local instance, result = Bloxdrive.load("nonexistent_package_id_00", {
            Version = 1,
        })

        assertEqual(result.Success, false, "Load should fail")
        assertEqual(instance, nil, "Instance should be nil on failure")
        assert(result.Error ~= nil, "Error should be set")
    end)

    -- Clean up test package
    HttpService:RequestAsync({
        Url = REGISTRY_URL .. "/packages/" .. TEST_PACKAGE_ID,
        Method = "DELETE",
        Headers = {
            Authorization = "Bearer " .. REGISTRY_TOKEN,
        },
    })
else
    test("Registry and load tests skipped (no REGISTRY_TOKEN)", function() end)
end

----------------------------------------------
-- Summary
----------------------------------------------

print("")
print("========================================")
print("E2E Test Results")
print("========================================")
print(passed .. " passed, " .. failed .. " failed")

if #errors > 0 then
    print("")
    print("Failures:")
    for _, err in errors do
        print("  " .. err)
    end
end

print("========================================")

return {
    Passed = passed,
    Failed = failed,
    Success = failed == 0,
}
