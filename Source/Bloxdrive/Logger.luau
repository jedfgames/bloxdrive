--[[

Logger

Simple logging module that prepends a consistent prefix to all output.
Supports verbosity levels: messages with a level higher than the
current verbosity are silenced. Default verbosity is 1.

--]]

local PREFIX = "[Bloxdrive]"
local DEFAULT_VERBOSITY = 1

local Logger = {}

Logger.Verbosity = DEFAULT_VERBOSITY

function Logger.print(message: string, level: number?)
    assert(type(message) == "string", "Expected a string message")
    if (level or 1) > Logger.Verbosity then
        return
    end
    print(`{PREFIX} {message}`)
end

function Logger.warn(message: string, level: number?)
    assert(type(message) == "string", "Expected a string message")
    if (level or 1) > Logger.Verbosity then
        return
    end
    warn(`{PREFIX} {message}`)
end

return Logger
