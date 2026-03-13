--[[

CredentialStore

Stores and retrieves the GitHub auth token using Roblox Studio's plugin
settings API. The token persists across Studio sessions.

--]]

local SETTING_KEY = "RbxPackageLoader_AuthToken"

local CredentialStore = {}

local _plugin: Plugin? = nil

--[=[
    Initializes the credential store with the plugin instance.

    @param pluginInstance Plugin -- The Studio plugin instance
]=]
function CredentialStore.init(pluginInstance: Plugin)
    assert(pluginInstance ~= nil, "Expected a Plugin instance")
    _plugin = pluginInstance
end

--[=[
    Returns the stored auth token, or nil if none is set.

    @return string? -- The auth token
]=]
function CredentialStore.getToken(): string?
    assert(_plugin ~= nil, "CredentialStore not initialized")
    local token = _plugin:GetSetting(SETTING_KEY)
    if type(token) == "string" and token ~= "" then
        return token
    end
    return nil
end

--[=[
    Stores an auth token in plugin settings.

    @param token string -- The auth token to store
]=]
function CredentialStore.setToken(token: string)
    assert(_plugin ~= nil, "CredentialStore not initialized")
    assert(type(token) == "string", "Expected a string token")
    _plugin:SetSetting(SETTING_KEY, token)
end

--[=[
    Clears the stored auth token.
]=]
function CredentialStore.clearToken()
    assert(_plugin ~= nil, "CredentialStore not initialized")
    _plugin:SetSetting(SETTING_KEY, nil)
end

--[=[
    Returns whether an auth token is stored.

    @return boolean -- Whether a token exists
]=]
function CredentialStore.hasToken(): boolean
    return CredentialStore.getToken() ~= nil
end

return CredentialStore
