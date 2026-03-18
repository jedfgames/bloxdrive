--[[

PackagePublisher

Handles publishing packages to the rbx-package-registry Cloudflare
Worker. Serializes a selected instance subtree into a tree and uploads
it as a new version via a single PUT request.

--]]

local HttpService = game:GetService("HttpService")

local DEFAULT_REGISTRY_URL = "https://rbx-package-registry.batchprogrammer314.workers.dev"

local MAX_PUBLISH_RETRIES = 3

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

--[=[
    Publishes a new version of a package to the registry. Serializes
    the given instance subtree, determines the next version number,
    and uploads the tree in a single request.

    @param serializer Serializer -- The serializer module
    @param options PublishOptions -- Publish configuration
    @return PublishResult -- The result of the publish operation
]=]
function PackagePublisher.publish(serializer: any, options: PublishOptions): PublishResult
    assert(type(options.PackageId) == "string", "Expected a string PackageId")
    assert(type(options.PackageName) == "string", "Expected a string PackageName")
    assert(typeof(options.Root) == "Instance", "Expected an Instance Root")
    assert(type(options.AuthToken) == "string", "Expected a string AuthToken")

    local baseUrl = options.BaseUrl or DEFAULT_REGISTRY_URL

    -- Serialize the tree up front
    local tree = serializer.serialize(options.Root)
    local treeJson = HttpService:JSONEncode(tree)

    for attempt = 1, MAX_PUBLISH_RETRIES do
        local success, result = pcall(function(): PublishResult
            -- Fetch current metadata to determine next version
            local metadata = _fetchMetadata(baseUrl, options.PackageId, options.AuthToken)
            local newVersion = metadata.LatestVersion + 1

            -- Single PUT to publish the version
            _putVersion(baseUrl, options.AuthToken, options.PackageId, options.PackageName, newVersion, treeJson)

            return {
                Success = true,
                Version = newVersion,
            }
        end)

        if success then
            return result
        end

        local errorStr = tostring(result)

        -- Retry on 409 Conflict (version already claimed by
        -- another publisher)
        local isConflict = string.find(errorStr, "409")
        if isConflict and attempt < MAX_PUBLISH_RETRIES then
            task.wait(1)
            continue
        end

        return {
            Success = false,
            Error = errorStr,
        }
    end

    return {
        Success = false,
        Error = "Exceeded maximum publish retries due to version conflicts.",
    }
end

function _fetchMetadata(baseUrl: string, packageId: string, authToken: string): { Name: string, LatestVersion: number }
    local url = `{baseUrl}/packages/{packageId}`

    local success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = url,
            Method = "GET",
            Headers = {
                Authorization = `Bearer {authToken}`,
            },
        })
    end)

    if success and response.Success then
        local decoded = HttpService:JSONDecode(response.Body)
        return {
            Name = decoded.name or packageId,
            LatestVersion = decoded.latestVersion or 0,
        }
    end

    -- Package doesn't exist yet (404)
    return {
        Name = packageId,
        LatestVersion = 0,
    }
end

function _putVersion(
    baseUrl: string,
    authToken: string,
    packageId: string,
    packageName: string,
    version: number,
    treeJson: string
)
    local url = `{baseUrl}/packages/{packageId}/versions/{version}`

    local putSuccess, putResponse = pcall(function()
        return HttpService:RequestAsync({
            Url = url,
            Method = "PUT",
            Headers = {
                Authorization = `Bearer {authToken}`,
                ["Content-Type"] = "application/json",
                ["X-Package-Name"] = packageName,
            },
            Body = treeJson,
        })
    end)

    if not putSuccess then
        error(`Failed to publish version {version}: {putResponse}`)
    end

    if not putResponse.Success then
        error(`Failed to publish version {version} ({putResponse.StatusCode}): {putResponse.Body}`)
    end
end

return PackagePublisher
