--[[

CredentialStore

Stores and retrieves the registry key using Roblox Studio's plugin
settings API. The key persists across Studio sessions.

--]]

local SETTING_KEY = "Bloxdrive_RegistryKey"

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
    Returns the stored registry key, or nil if none is set.

    @return string? -- The registry key
]=]
function CredentialStore.getKey(): string?
    assert(_plugin ~= nil, "CredentialStore not initialized")
    local key = _plugin:GetSetting(SETTING_KEY)
    if type(key) == "string" and key ~= "" then
        return key
    end
    return nil
end

--[=[
    Stores a registry key in plugin settings.

    @param key string -- The registry key to store
]=]
function CredentialStore.setKey(key: string)
    assert(_plugin ~= nil, "CredentialStore not initialized")
    assert(type(key) == "string", "Expected a string key")
    _plugin:SetSetting(SETTING_KEY, key)
end

--[=[
    Clears the stored registry key.
]=]
function CredentialStore.clearKey()
    assert(_plugin ~= nil, "CredentialStore not initialized")
    _plugin:SetSetting(SETTING_KEY, nil)
end

--[=[
    Returns whether a registry key is stored.

    @return boolean -- Whether a key exists
]=]
function CredentialStore.hasKey(): boolean
    return CredentialStore.getKey() ~= nil
end

return CredentialStore
