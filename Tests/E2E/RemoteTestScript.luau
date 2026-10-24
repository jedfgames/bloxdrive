--!nocheck

--[[

RemoteTestScript

Test script that runs inside a real Roblox place via the Open Cloud Luau
Execution API. Exercises Serializer, Deserializer, PropertyReflection,
TreeDiff, Merger, Registry, and Bloxdrive.load with real instances.

The placeholder __REGISTRY_TOKEN__ is replaced at runtime by E2E.spec.luau
before submitting to the execution API.

--]]

const REGISTRY_TOKEN = __REGISTRY_TOKEN__

const ok, Bloxdrive = pcall(require, game.ReplicatedStorage.Source.Bloxdrive)
if not ok then
    print("[FAIL] Module load - " .. tostring(Bloxdrive))
    return { Passed = 0, Failed = 1, Success = false }
end

const Deserializer = Bloxdrive.Deserializer
const Merger = Bloxdrive.Merger
const PropertyReflection = Bloxdrive.PropertyReflection
const Serializer = Bloxdrive.Serializer
const TreeDiff = Bloxdrive.TreeDiff
const TreeUtils = Bloxdrive.TreeUtils

local passed = 0
local failed = 0
const errors = {}

const function test(name, fn)
    const success, err = pcall(fn)
    if success then
        passed += 1
        print("[PASS] " .. name)
    else
        failed += 1
        table.insert(errors, name .. ": " .. tostring(err))
        print("[FAIL] " .. name .. " - " .. tostring(err))
    end
end

const function assertEqual(actual, expected, message)
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
    const part = Instance.new("Part")
    part.Anchored = true
    part.Size = Vector3.new(4, 8, 2)
    part.Parent = workspace

    const props = PropertyReflection.getSerializableProperties(part)
    assertEqual(props.Anchored, true, "Anchored")

    assert(props.size ~= nil or props.Size ~= nil, "Size property not found")
    const sizeVal = props.size or props.Size
    assert(type(sizeVal) == "table", "Size should be a table")
    assert(sizeVal.Vector3 ~= nil, "Size should have Vector3 key")
    assertEqual(sizeVal.Vector3[1], 4, "Size X")
    assertEqual(sizeVal.Vector3[2], 8, "Size Y")
    assertEqual(sizeVal.Vector3[3], 2, "Size Z")

    part:Destroy()
end)

test("PropertyReflection sets Part properties", function()
    const part = Instance.new("Part")
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
    const light = Instance.new("SpotLight")
    light.Color = Color3.new(1, 0, 0.5)
    light.Parent = workspace

    const props = PropertyReflection.getSerializableProperties(light)
    const color = props.Color or props.color
    assert(color ~= nil, "Color property not found")
    assert(type(color) == "table", "Color should be a table")
    assert(color.Color3 ~= nil, "Color should have Color3 key")

    light:Destroy()
end)

test("PropertyReflection handles CFrame", function()
    const part = Instance.new("Part")
    part.CFrame = CFrame.new(1, 2, 3)
    part.Parent = workspace

    const props = PropertyReflection.getSerializableProperties(part)
    const cf = props.CFrame
    assert(cf ~= nil, "CFrame property not found")
    assert(cf.CFrame ~= nil, "CFrame should have CFrame key")
    assertEqual(cf.CFrame.position[1], 1, "CFrame position X")

    part:Destroy()
end)

----------------------------------------------
-- Serializer round-trip tests
----------------------------------------------

test("Serialize and deserialize a simple folder", function()
    const folder = Instance.new("Folder")
    folder.Name = "TestPkg"
    folder.Parent = workspace

    const child1 = Instance.new("NumberValue")
    child1.Name = "Health"
    child1.Value = 100
    child1.Parent = folder

    const child2 = Instance.new("StringValue")
    child2.Name = "Label"
    child2.Value = "hello"
    child2.Parent = folder

    const tree = Serializer.serialize(folder)
    assertEqual(tree["$className"], "Folder")
    assert(tree.Health ~= nil, "Health child missing")
    assert(tree.Label ~= nil, "Label child missing")
    assertEqual(tree.Health["$className"], "NumberValue")
    assertEqual(tree.Label["$className"], "StringValue")

    folder:Destroy()
end)

test("Serialize skips .bloxdrive marker", function()
    const folder = Instance.new("Folder")
    folder.Name = "TestPkg"
    folder.Parent = workspace

    const marker = Instance.new("StringValue")
    marker.Name = ".bloxdrive"
    marker.Value = '{"Id":"test","Version":1}'
    marker.Parent = folder

    const child = Instance.new("Folder")
    child.Name = "Content"
    child.Parent = folder

    const tree = Serializer.serialize(folder)
    assertEqual(tree[".bloxdrive"], nil, "Marker should be skipped")
    assert(tree.Content ~= nil, "Content child should exist")

    folder:Destroy()
end)

test("Serialize handles duplicate child names", function()
    const folder = Instance.new("Folder")
    folder.Name = "TestPkg"
    folder.Parent = workspace

    const c1 = Instance.new("Part")
    c1.Name = "Block"
    c1.Parent = folder

    const c2 = Instance.new("Part")
    c2.Name = "Block"
    c2.Parent = folder

    const tree = Serializer.serialize(folder)
    assert(tree.Block ~= nil, "Block should exist")
    assert(tree.Block1 ~= nil, "Block1 should exist (auto-incremented)")

    const names = {}
    for _, child in folder:GetChildren() do
        table.insert(names, child.Name)
    end
    table.sort(names)
    assertEqual(names[1], "Block", "First child name")
    assertEqual(names[2], "Block1", "Second child name")

    folder:Destroy()
end)

test("Serialize round-trip preserves structure", function()
    const root = Instance.new("Folder")
    root.Name = "RoundTrip"
    root.Parent = workspace

    const sub = Instance.new("Folder")
    sub.Name = "SubFolder"
    sub.Parent = root

    const part = Instance.new("Part")
    part.Name = "MyPart"
    part.Anchored = true
    part.Size = Vector3.new(5, 10, 15)
    part.Parent = sub

    const tree1 = Serializer.serialize(root)

    const reconstructed = Instance.new("Folder")
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

    const tree2 = Serializer.serialize(reconstructed)

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
    const folder1 = Instance.new("Folder")
    folder1.Name = "Pkg"
    folder1.Parent = workspace

    const part1 = Instance.new("Part")
    part1.Name = "Block"
    part1.Anchored = true
    part1.Size = Vector3.new(4, 4, 4)
    part1.Parent = folder1

    const folder2 = Instance.new("Folder")
    folder2.Name = "Pkg"
    folder2.Parent = workspace

    const part2 = Instance.new("Part")
    part2.Name = "Block"
    part2.Anchored = true
    part2.Size = Vector3.new(4, 8, 4)
    part2.Parent = folder2

    const tree1 = Serializer.serialize(folder1)
    const tree2 = Serializer.serialize(folder2)

    const ops = TreeDiff.diff(tree1, tree2)
    assert(#ops > 0, "Should have diff operations for size change")

    local foundSize = false
    for _, op in ops do
        if op.Kind == "Modify" then
            const pathStr = table.concat(op.Path, ".")
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
    const base = Instance.new("Folder")
    base.Name = "MergeTest"
    base.Parent = workspace

    const health = Instance.new("NumberValue")
    health.Name = "Health"
    health.Value = 100
    health.Parent = base

    const speed = Instance.new("NumberValue")
    speed.Name = "Speed"
    speed.Value = 10
    speed.Parent = base

    const baseTree = Serializer.serialize(base)

    health.Value = 200
    const localTree = Serializer.serialize(base)

    health.Value = 100
    speed.Value = 20
    const remoteTree = Serializer.serialize(base)

    const result = Merger.merge(baseTree, localTree, remoteTree)
    assertEqual(#result.Conflicts, 0, "Should have no conflicts")

    const mergedHealth = result.Tree.Health["$properties"]
    const mergedSpeed = result.Tree.Speed["$properties"]

    const healthVal = mergedHealth.Value or mergedHealth.value
    const speedVal = mergedSpeed.Value or mergedSpeed.value
    assertEqual(healthVal, 200, "Health should be local's value")
    assertEqual(speedVal, 20, "Speed should be remote's value")

    base:Destroy()
end)

test("Three-way merge detects conflicts", function()
    const base = Instance.new("Folder")
    base.Name = "ConflictTest"
    base.Parent = workspace

    const val = Instance.new("NumberValue")
    val.Name = "Score"
    val.Value = 50
    val.Parent = base

    const baseTree = Serializer.serialize(base)

    val.Value = 100
    const localTree = Serializer.serialize(base)

    val.Value = 200
    const remoteTree = Serializer.serialize(base)

    val.Value = 50

    const result = Merger.merge(baseTree, localTree, remoteTree)
    assert(#result.Conflicts > 0, "Should have conflicts")

    const mergedScore = result.Tree.Score["$properties"]
    const scoreVal = mergedScore.Value or mergedScore.value
    assertEqual(scoreVal, 100, "Local should win conflicts")

    base:Destroy()
end)

----------------------------------------------
-- Surgical apply tests
----------------------------------------------

test("Surgical property update via TreeDiff", function()
    const folder = Instance.new("Folder")
    folder.Name = "SurgicalTest"
    folder.Parent = workspace

    const part = Instance.new("Part")
    part.Name = "Target"
    part.Anchored = true
    part.Size = Vector3.new(4, 4, 4)
    part.Parent = folder

    const currentTree = Serializer.serialize(folder)

    const targetTree = TreeUtils.deepClone(currentTree)
    targetTree.Target["$properties"].size = { Vector3 = { 4, 10, 4 } }

    const ops = TreeDiff.diff(currentTree, targetTree)
    assert(#ops > 0, "Should have diff ops")

    for _, op in ops do
        if op.Kind == "Modify" then
            const pathStr = table.concat(op.Path, ".")
            if string.find(pathStr, "size") or string.find(pathStr, "Size") then
                PropertyReflection.setProperty(part, "size", op.NewValue)
            end
        end
    end

    assertEqual(part.Size.Y, 10, "Size Y should be updated surgically")

    folder:Destroy()
end)

test("Surgical child addition via TreeDiff", function()
    const folder = Instance.new("Folder")
    folder.Name = "AddTest"
    folder.Parent = workspace

    const existing = Instance.new("NumberValue")
    existing.Name = "Existing"
    existing.Value = 42
    existing.Parent = folder

    const currentTree = Serializer.serialize(folder)

    const targetTree = TreeUtils.deepClone(currentTree)
    targetTree.NewChild = {
        ["$className"] = "StringValue",
        ["$properties"] = { Value = "hello" },
    }

    const ops = TreeDiff.diff(currentTree, targetTree)

    const addOps = {}
    for _, op in ops do
        if op.Kind == "Add" and op.Path[1] == "NewChild" then
            table.insert(addOps, op)
        end
    end
    assert(#addOps > 0, "Should have Add op for NewChild")

    Deserializer.deserialize("NewChild", addOps[1].Node, folder)

    const newChild = folder:FindFirstChild("NewChild")
    assert(newChild ~= nil, "NewChild should exist after surgical add")
    assertEqual(newChild.ClassName, "StringValue", "NewChild className")
    assertEqual(existing.Value, 42, "Existing value should be unchanged")

    folder:Destroy()
end)

test("Surgical child removal via TreeDiff", function()
    const folder = Instance.new("Folder")
    folder.Name = "RemoveTest"
    folder.Parent = workspace

    const keep = Instance.new("NumberValue")
    keep.Name = "Keep"
    keep.Value = 1
    keep.Parent = folder

    const remove = Instance.new("StringValue")
    remove.Name = "Remove"
    remove.Value = "bye"
    remove.Parent = folder

    const currentTree = Serializer.serialize(folder)

    const targetTree = TreeUtils.deepClone(currentTree)
    targetTree.Remove = nil

    const ops = TreeDiff.diff(currentTree, targetTree)

    for _, op in ops do
        if op.Kind == "Remove" and op.Path[1] == "Remove" then
            const child = folder:FindFirstChild("Remove")
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
    const root = Instance.new("Folder")
    root.Name = "FilesTest"
    root.Parent = workspace

    const container = Instance.new("Folder")
    container.Name = "Models"
    container.Parent = root

    const leaf = Instance.new("Part")
    leaf.Name = "Block"
    leaf.Anchored = true
    leaf.Parent = container

    const topLeaf = Instance.new("NumberValue")
    topLeaf.Name = "Score"
    topLeaf.Value = 100
    topLeaf.Parent = root

    const tree = Serializer.serialize(root)
    const fileResult = Serializer.serializeToFiles(tree)

    assert(fileResult.Files["instance.json"] ~= nil, "Root instance.json")
    assert(fileResult.Files["Score.json"] ~= nil, "Score.json")
    assert(fileResult.Files["Models/instance.json"] ~= nil, "Models/instance.json")
    assert(fileResult.Files["Models/Block.json"] ~= nil, "Models/Block.json")

    const reassembled = Deserializer.reassembleTree(fileResult.Files)
    assertEqual(reassembled["$className"], "Folder", "Root className")
    assert(reassembled.Models ~= nil, "Models child")
    assert(reassembled.Models.Block ~= nil, "Block child")
    assert(reassembled.Score ~= nil, "Score child")

    root:Destroy()
end)

----------------------------------------------
-- Registry and load tests
----------------------------------------------

const REGISTRY_URL = "https://rbx-package-registry.batchprogrammer314.workers.dev"
const TEST_PACKAGE_ID = "e2e-remote-fixture"
const HttpService = game:GetService("HttpService")

if REGISTRY_TOKEN then
    -- Seed a test package for the registry and load tests
    const seedTree = {
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
        const Registry = Bloxdrive.Registry
        const registry = Registry.new({ RegistryKey = REGISTRY_TOKEN })

        const metadata = registry:FetchMetadata(TEST_PACKAGE_ID)
        assertEqual(metadata.Name, "E2EFixture", "Name should match")
        assertEqual(metadata.LatestVersion, 1, "LatestVersion should be 1")
    end)

    test("Registry fetches a specific version", function()
        const Registry = Bloxdrive.Registry
        const registry = Registry.new({ RegistryKey = REGISTRY_TOKEN })

        const tree = registry:FetchVersion(TEST_PACKAGE_ID, 1)
        assertEqual(tree["$className"], "Folder", "className should be Folder")
        assert(tree.Health ~= nil, "Health child should exist")
    end)

    test("Registry fetches latest version", function()
        const Registry = Bloxdrive.Registry
        const registry = Registry.new({ RegistryKey = REGISTRY_TOKEN })

        const tree, version = registry:FetchLatest(TEST_PACKAGE_ID)
        assertEqual(version, 1, "Latest version should be 1")
        assertEqual(tree["$className"], "Folder", "className should be Folder")
    end)

    Bloxdrive.configure({ RegistryKey = REGISTRY_TOKEN })

    test("load returns instance and result with Parent", function()
        const parent = Instance.new("Folder")
        parent.Name = "LoadTestParent"
        parent.Parent = workspace

        const instance, result = Bloxdrive.load(TEST_PACKAGE_ID, {
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
        const instance, result = Bloxdrive.load(TEST_PACKAGE_ID, {
            Version = 1,
        })

        assert(result.Success, "Load should succeed: " .. tostring(result.Error))
        assert(instance ~= nil, "Instance should not be nil")
        assertEqual(instance.Parent, nil, "Instance should not be parented")

        instance:Destroy()
    end)

    test("load returns nil instance on failure", function()
        const instance, result = Bloxdrive.load("nonexistent_package_id_00", {
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
