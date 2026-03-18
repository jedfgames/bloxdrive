--[[

Registry

HTTP client for fetching packages from the rbx-package-registry
Cloudflare Worker. Retrieves package metadata and versioned instance
trees via a simple REST API backed by D1 (SQLite at the edge).

--]]

local HttpService = game:GetService("HttpService")

local DEFAULT_BASE_URL = "https://rbx-package-registry.batchprogrammer314.workers.dev"

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
    > configuration. Defaults to the Workers registry URL.
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

    local response = self:_get(`{self._baseUrl}/packages/{packageId}`)
    local metadata = HttpService:JSONDecode(response)

    return {
        Name = metadata.name,
        LatestVersion = metadata.latestVersion,
    }
end

--[=[
    Fetches a specific version of a package from the registry.

    @param packageId string -- The package identifier
    @param version number -- The version number to fetch
    @return TreeNode -- The deserialized tree for that version
]=]
function Registry.FetchVersion(self: Registry, packageId: string, version: number): { [string]: any }
    assert(type(packageId) == "string", "Expected a string packageId")
    assert(type(version) == "number", "Expected a number version")

    local response = self:_get(`{self._baseUrl}/packages/{packageId}/versions/{version}`)
    local tree = HttpService:JSONDecode(response)

    assert(type(tree) == "table", `Invalid tree for "{packageId}" version {version}`)
    assert(tree["$className"] ~= nil, `Missing $className for "{packageId}" version {version}`)

    return tree
end

--[=[
    Fetches the latest version of a package from the registry. First
    retrieves metadata to determine the latest version number, then
    fetches that version's tree.

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
    local headers: { [string]: string }? = nil
    if self._authToken then
        headers = {
            Authorization = `Bearer {self._authToken}`,
        }
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
