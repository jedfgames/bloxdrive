--[[

PackageScanner

Scans the Roblox DataModel for `.rbx-package` StringValue markers. Each
marker identifies a managed package subtree with its ID, version, and
auto-update preference.

--]]

local HttpService = game:GetService("HttpService")

local PACKAGE_MARKER_NAME = ".rbx-package"

local PackageScanner = {}

type PackageMarker = {
    Id: string,
    Version: number,
    AutoUpdate: boolean,
}

type PackageInfo = {
    Marker: StringValue,
    Parent: Instance,
    Metadata: PackageMarker,
}

--[=[
    Scans the given roots (or the entire DataModel) for `.rbx-package`
    StringValue markers. Parses their JSON metadata and returns information
    about each discovered package.

    @param roots { Instance }? -- The roots to scan. Defaults to `{ game }`.
    @return { PackageInfo } -- The discovered packages
]=]
function PackageScanner.scan(roots: { Instance }?): { PackageInfo }
    local scanRoots = roots or { game }
    local results: { PackageInfo } = {}

    for _, root in scanRoots do
        _scanDescendants(root, results)
    end

    return results
end

function _scanDescendants(root: Instance, results: { PackageInfo })
    for _, descendant in root:GetDescendants() do
        if not descendant:IsA("StringValue") then
            continue
        end

        if descendant.Name ~= PACKAGE_MARKER_NAME then
            continue
        end

        local parent = descendant.Parent
        if parent == nil then
            continue
        end

        local success, metadata = pcall(function(): PackageMarker
            local decoded = HttpService:JSONDecode(descendant.Value)

            assert(type(decoded.Id) == "string", "Missing Id in package marker")
            assert(type(decoded.Version) == "number", "Missing Version in package marker")

            return {
                Id = decoded.Id,
                Version = decoded.Version,
                AutoUpdate = if type(decoded.AutoUpdate) == "boolean" then decoded.AutoUpdate else false,
            }
        end)

        if success then
            table.insert(results, {
                Marker = descendant,
                Parent = parent,
                Metadata = metadata,
            })
        else
            warn(`Failed to parse package marker under "{parent:GetFullName()}": {metadata}`)
        end
    end
end

return PackageScanner
