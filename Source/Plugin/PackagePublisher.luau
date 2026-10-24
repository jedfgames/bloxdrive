--[[

PackagePublisher

Handles publishing packages to the bloxdrive-registry Cloudflare
Worker. Serializes a selected instance subtree into a tree and uploads
it as a new version via a single PUT request.

--]]

const HttpService = game:GetService("HttpService")

const DEFAULT_REGISTRY_URL = "https://rbx-package-registry.batchprogrammer314.workers.dev"

const MAX_PUBLISH_RETRIES = 3

const PackagePublisher = {}

type PublishOptions = {
    PackageId: string,
    PackageName: string,
    Root: Instance,
    RegistryKey: string,
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
    assert(type(options.RegistryKey) == "string", "Expected a string RegistryKey")

    const baseUrl = options.BaseUrl or DEFAULT_REGISTRY_URL

    -- Serialize the tree up front
    const tree = serializer.serialize(options.Root)
    const treeJson = HttpService:JSONEncode(tree)

    for attempt = 1, MAX_PUBLISH_RETRIES do
        const success, result = pcall(function(): PublishResult
            -- Fetch current metadata to determine next version
            const metadata = _fetchMetadata(baseUrl, options.PackageId, options.RegistryKey)
            const newVersion = metadata.LatestVersion + 1

            -- Single PUT to publish the version
            _putVersion(baseUrl, options.RegistryKey, options.PackageId, options.PackageName, newVersion, treeJson)

            return {
                Success = true,
                Version = newVersion,
            }
        end)

        if success then
            return result
        end

        const errorStr = tostring(result)

        -- Retry on 409 Conflict (version already claimed by
        -- another publisher)
        const isConflict = string.find(errorStr, "409")
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

function _fetchMetadata(
    baseUrl: string,
    packageId: string,
    registryKey: string
): { Name: string, LatestVersion: number }
    const url = `{baseUrl}/packages/{packageId}`

    const success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = url,
            Method = "GET",
            Headers = {
                Authorization = `Bearer {registryKey}`,
            },
        })
    end)

    if success and response.Success then
        const decoded = HttpService:JSONDecode(response.Body)
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
    registryKey: string,
    packageId: string,
    packageName: string,
    version: number,
    treeJson: string
)
    const url = `{baseUrl}/packages/{packageId}/versions/{version}`

    const putSuccess, putResponse = pcall(function()
        return HttpService:RequestAsync({
            Url = url,
            Method = "PUT",
            Headers = {
                Authorization = `Bearer {registryKey}`,
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
