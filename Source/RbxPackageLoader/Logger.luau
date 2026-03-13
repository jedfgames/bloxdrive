--[[

Logger

Simple logging module that prepends a consistent prefix to all output.

--]]

local PREFIX = "[rbx-package-loader]"

local Logger = {}

function Logger.print(message: string)
    assert(type(message) == "string", "Expected a string message")
    print(`{PREFIX} {message}`)
end

function Logger.warn(message: string)
    assert(type(message) == "string", "Expected a string message")
    warn(`{PREFIX} {message}`)
end

return Logger
