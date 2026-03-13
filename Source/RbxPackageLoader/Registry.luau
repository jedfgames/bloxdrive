--[[

Registry

HTTP client for fetching packages from the jedfgames/rbx-package-registry
GitHub repository. Retrieves package metadata and versioned instance files
via GitHub's raw content URLs. Supports both the new hierarchical format
(manifest.json + individual files) and the legacy single tree.json format.

--]]

local HttpService = game:GetService("HttpService")

local Deserializer = require("@self/Deserializer")

local API_BASE_URL = "https://api.github.com/repos/jedfgames/rbx-package-registry/contents"
local DEFAULT_BASE_URL = "https://raw.githubusercontent.com/jedfgames/rbx-package-registry/main"

local Registry = {}
Registry.__index = Registry

export type Registry = typeof(setmetatable(
    {} :: {
        _baseUrl: string,
        _authToken: string?,
    },
    Registry
))

--[=[
    Creates a new Registry client.

    @param config { BaseUrl: string?, AuthToken: string? }? -- Optional
    > configuration. Defaults to the jedfgames/rbx-package-registry raw URL.
    @return Registry -- The registry client
]=]
function Registry.new(config: { BaseUrl: string?, AuthToken: string? }?): Registry
    local self = setmetatable({}, Registry)
    self._baseUrl = if config and config.BaseUrl then config.BaseUrl else DEFAULT_BASE_URL
    self._authToken = if config then config.AuthToken else nil
    return self
end

--[=[
    Fetches the metadata for a package from the registry.

    @param packageId string -- The package identifier
    @return { Name: string, LatestVersion: number } -- The package metadata
]=]
function Registry.FetchMetadata(self: Registry, packageId: string): { Name: string, LatestVersion: number }
    assert(type(packageId) == "string", "Expected a string packageId")

    -- Use the GitHub API with raw content accept header to avoid CDN
    -- caching that raw.githubusercontent.com applies
    local url = `{API_BASE_URL}/packages/{packageId}/metadata.json`
    local headers: { [string]: string } = {
        Accept = "application/vnd.github.v3.raw",
    }
    if self._authToken then
        headers["Authorization"] = `token {self._authToken}`
    end

    local success, response = pcall(function()
        return HttpService:GetAsync(url, true, headers)
    end)

    if not success then
        error(`Failed to fetch metadata for "{packageId}": {response}`)
    end

    local metadata = HttpService:JSONDecode(response)

    -- Registry JSON uses lowercase keys (name, latestVersion) so normalize
    -- to PascalCase for consistency with our Luau conventions
    local normalized = {
        Name = metadata.name or metadata.Name,
        LatestVersion = metadata.latestVersion or metadata.LatestVersion,
    }

    assert(type(normalized.Name) == "string", `Invalid metadata for "{packageId}": missing name`)
    assert(type(normalized.LatestVersion) == "number", `Invalid metadata for "{packageId}": missing latestVersion`)

    return normalized
end

--[=[
    Fetches a specific version of a package from the registry. Tries the
    new hierarchical format first (manifest.json + individual files), then
    falls back to the legacy single tree.json format.

    @param packageId string -- The package identifier
    @param version number -- The version number to fetch
    @return TreeNode -- The deserialized tree for that version
]=]
function Registry.FetchVersion(self: Registry, packageId: string, version: number): { [string]: any }
    assert(type(packageId) == "string", "Expected a string packageId")
    assert(type(version) == "number", "Expected a number version")

    local versionBase = `{self._baseUrl}/packages/{packageId}/versions/{version}`

    -- Try new hierarchical format first
    local manifestSuccess, manifestResponse = pcall(function()
        return self:_get(`{versionBase}/manifest.json`)
    end)

    if manifestSuccess then
        local manifest = HttpService:JSONDecode(manifestResponse)
        local files: { [string]: any } = {}

        for _, filePath in manifest.files do
            local fileResponse = self:_get(`{versionBase}/{filePath}`)
            files[filePath] = HttpService:JSONDecode(fileResponse)
        end

        return Deserializer.reassembleTree(files)
    end

    -- Fall back to legacy tree.json format
    local response = self:_get(`{versionBase}/tree.json`)
    local tree = HttpService:JSONDecode(response)

    assert(type(tree) == "table", `Invalid tree.json for "{packageId}" version {version}`)
    assert(tree["$className"] ~= nil, `Missing $className in tree.json for "{packageId}" version {version}`)

    return tree
end

--[=[
    Fetches the latest version of a package from the registry. First
    retrieves metadata to determine the latest version number, then fetches
    that version's tree.

    @param packageId string -- The package identifier
    @return TreeNode -- The deserialized tree
    @return number -- The latest version number
]=]
function Registry.FetchLatest(self: Registry, packageId: string): ({ [string]: any }, number)
    local metadata = self:FetchMetadata(packageId)
    local tree = self:FetchVersion(packageId, metadata.LatestVersion)
    return tree, metadata.LatestVersion
end

function Registry._get(self: Registry, url: string): string
    local headers = {}
    if self._authToken then
        headers["Authorization"] = `token {self._authToken}`
    end

    local success, response = pcall(function()
        return HttpService:GetAsync(url, true, headers)
    end)

    if not success then
        error(`Failed to fetch from registry: {response}\n  URL: {url}`)
    end

    return response
end

return Registry
