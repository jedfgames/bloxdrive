--[[

PackagePublisher

Handles publishing packages to the jedfgames/rbx-package-registry GitHub
repo. Serializes a selected instance subtree into a hierarchical file
structure and pushes it as a new version via the GitHub Contents API.

Each instance becomes its own file: leaf instances are `Name.json`,
containers are directories with `instance.json`. A `manifest.json`
listing all files is uploaded last as the commit point.

--]]

local HttpService = game:GetService("HttpService")

local PackagePublisher = {}

type PublishOptions = {
    PackageId: string,
    PackageName: string,
    Root: Instance,
    AuthToken: string,
    BaseUrl: string?,
}

type PublishResult = {
    Success: boolean,
    Version: number?,
    Error: string?,
}

local REGISTRY_OWNER = "jedfgames"
local REGISTRY_REPO = "rbx-package-registry"
local API_BASE = "https://api.github.com"

--[=[
    Publishes a new version of a package to the registry. Serializes the
    given instance subtree into hierarchical files, increments the version
    number, and pushes all files plus updated metadata.json to GitHub.

    @param serializer Serializer -- The serializer module
    @param options PublishOptions -- Publish configuration
    @return PublishResult -- The result of the publish operation
]=]
function PackagePublisher.publish(serializer: any, options: PublishOptions): PublishResult
    assert(type(options.PackageId) == "string", "Expected a string PackageId")
    assert(type(options.PackageName) == "string", "Expected a string PackageName")
    assert(typeof(options.Root) == "Instance", "Expected an Instance Root")
    assert(type(options.AuthToken) == "string", "Expected a string AuthToken")

    local success, result = pcall(function(): PublishResult
        -- Serialize the instance tree into hierarchical files
        local tree = serializer.serialize(options.Root)
        local serialized = serializer.serializeToFiles(tree)

        -- Fetch current metadata (or create new)
        local metadata = _fetchOrCreateMetadata(options.PackageId, options.PackageName, options.AuthToken)
        local newVersion = metadata.LatestVersion + 1
        local versionPath = `packages/{options.PackageId}/versions/{newVersion}`

        -- Upload all instance files first
        for filePath, content in serialized.Files do
            local jsonContent = HttpService:JSONEncode(content)
            _uploadFile(
                options.AuthToken,
                `{versionPath}/{filePath}`,
                jsonContent,
                `Publish {options.PackageId} v{newVersion}: {filePath}`
            )
        end

        -- Upload manifest.json last (acts as the commit point)
        local manifestJson = HttpService:JSONEncode({ files = serialized.Manifest })
        _uploadFile(
            options.AuthToken,
            `{versionPath}/manifest.json`,
            manifestJson,
            `Publish {options.PackageId} v{newVersion}: manifest`
        )

        -- Update metadata.json
        metadata.LatestVersion = newVersion
        local metadataJson = HttpService:JSONEncode({
            name = metadata.Name,
            latestVersion = metadata.LatestVersion,
        })
        _uploadFile(
            options.AuthToken,
            `packages/{options.PackageId}/metadata.json`,
            metadataJson,
            `Update {options.PackageId} metadata to version {newVersion}`
        )

        return {
            Success = true,
            Version = newVersion,
        }
    end)

    if not success then
        return {
            Success = false,
            Error = tostring(result),
        }
    end

    return result
end

function _fetchOrCreateMetadata(
    packageId: string,
    packageName: string,
    authToken: string
): { Name: string, LatestVersion: number }
    local url = `{API_BASE}/repos/{REGISTRY_OWNER}/{REGISTRY_REPO}/contents/packages/{packageId}/metadata.json`

    local success, response = pcall(function()
        return HttpService:GetAsync(url, true, {
            Authorization = `token {authToken}`,
            Accept = "application/vnd.github.v3.raw",
        })
    end)

    if success and response then
        local decoded = HttpService:JSONDecode(response)
        return {
            Name = decoded.name or decoded.Name or packageId,
            LatestVersion = decoded.latestVersion or decoded.LatestVersion or 0,
        }
    end

    -- Package doesn't exist yet, create initial metadata
    return {
        Name = packageName,
        LatestVersion = 0,
    }
end

function _uploadFile(authToken: string, path: string, content: string, message: string)
    local url = `{API_BASE}/repos/{REGISTRY_OWNER}/{REGISTRY_REPO}/contents/{path}`

    -- Check if file already exists to get its SHA (needed for updates)
    local sha: string? = nil
    local checkSuccess, checkResponse = pcall(function()
        return HttpService:GetAsync(url, true, {
            Authorization = `token {authToken}`,
            Accept = "application/vnd.github.v3+json",
        })
    end)

    if checkSuccess and checkResponse then
        local decoded = HttpService:JSONDecode(checkResponse)
        sha = decoded.sha
    end

    -- Base64 encode the content
    local encoded = _base64Encode(content)

    local body: { [string]: any } = {
        message = message,
        content = encoded,
    }

    if sha then
        body.sha = sha
    end

    local requestBody = HttpService:JSONEncode(body)

    local putSuccess, putResponse = pcall(function()
        return HttpService:RequestAsync({
            Url = url,
            Method = "PUT",
            Headers = {
                Authorization = `token {authToken}`,
                ["Content-Type"] = "application/json",
                Accept = "application/vnd.github.v3+json",
            },
            Body = requestBody,
        })
    end)

    if not putSuccess then
        error(`Failed to upload file "{path}": {putResponse}`)
    end

    if not putResponse.Success then
        error(`Failed to upload file "{path}" ({putResponse.StatusCode}): {putResponse.Body}`)
    end
end

function _base64Encode(data: string): string
    local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local result = {}

    local i = 1
    while i <= #data do
        local a = string.byte(data, i)
        local b = if i + 1 <= #data then string.byte(data, i + 1) else 0
        local c = if i + 2 <= #data then string.byte(data, i + 2) else 0

        local remaining = #data - i + 1

        local n = a * 65536 + b * 256 + c

        table.insert(result, string.sub(CHARS, bit32.rshift(n, 18) + 1, bit32.rshift(n, 18) + 1))
        table.insert(
            result,
            string.sub(CHARS, bit32.band(bit32.rshift(n, 12), 63) + 1, bit32.band(bit32.rshift(n, 12), 63) + 1)
        )

        if remaining >= 2 then
            table.insert(
                result,
                string.sub(CHARS, bit32.band(bit32.rshift(n, 6), 63) + 1, bit32.band(bit32.rshift(n, 6), 63) + 1)
            )
        else
            table.insert(result, "=")
        end

        if remaining >= 3 then
            table.insert(result, string.sub(CHARS, bit32.band(n, 63) + 1, bit32.band(n, 63) + 1))
        else
            table.insert(result, "=")
        end

        i += 3
    end

    return table.concat(result)
end

return PackagePublisher
