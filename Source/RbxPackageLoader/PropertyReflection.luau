--[[

PropertyReflection

Reads and writes instance properties using Roblox's ReflectionService.
Dynamically enumerates serializable properties for any ClassName, avoiding
the need for a hand-curated property list.

The reflection provider is pluggable for testing. In production, it uses
ReflectionService. In Lune tests, a mock provider can be injected via
`setProvider`.

This module requires Roblox APIs (game, HttpService, ReflectionService) and
should only be required from code that runs in Studio or at runtime, not
from pure-data modules like TreeDiff or Merger.

--]]

-- Some properties are reported as serializable by ReflectionService but
-- cannot be accessed by their reflected name. This map provides the
-- public API name to use instead.
local PROPERTY_ALIASES: { [string]: string } = {
    Color3uint8 = "Color",
    MaterialVariantSerialized = "MaterialVariant",
}

-- Properties that are serializable according to ReflectionService but
-- should be skipped entirely. Includes legacy surface joint params,
-- runtime physics state, and redundant collision group ID.
local SKIP_PROPERTIES: { [string]: boolean } = {
    BackParamA = true,
    BackParamB = true,
    BackSurfaceInput = true,
    BottomParamA = true,
    BottomParamB = true,
    BottomSurfaceInput = true,
    CollisionGroupId = true,
    FrontParamA = true,
    FrontParamB = true,
    FrontSurfaceInput = true,
    LeftParamA = true,
    LeftParamB = true,
    LeftSurfaceInput = true,
    RightParamA = true,
    RightParamB = true,
    RightSurfaceInput = true,
    RotVelocity = true,
    TopParamA = true,
    TopParamB = true,
    TopSurfaceInput = true,
    Velocity = true,
    formFactorRaw = true,
}

local PropertyReflection = {}

type PropertyInfo = {
    Name: string,
    Type: string,
    Serialized: boolean,
}

type ReflectionProvider = {
    GetSerializableProperties: (self: ReflectionProvider, className: string) -> { PropertyInfo },
}

local _provider: ReflectionProvider? = nil

local function _getDefaultProvider(): ReflectionProvider
    local reflectionService = game:GetService("ReflectionService")

    local provider = {} :: ReflectionProvider

    function provider.GetSerializableProperties(self: ReflectionProvider, className: string): { PropertyInfo }
        local reflected = reflectionService:GetPropertiesOfClass(className)
        local result = {}

        for _, prop in reflected do
            if prop.Serialized then
                table.insert(result, {
                    Name = prop.Name,
                    Type = tostring(prop.Type),
                    Serialized = true,
                })
            end
        end

        return result
    end

    return provider
end

local function _getProvider(): ReflectionProvider
    if not _provider then
        _provider = _getDefaultProvider()
    end
    return _provider :: ReflectionProvider
end

--[=[
    Injects a custom reflection provider, used for testing in Lune where
    ReflectionService is not available.

    @param provider ReflectionProvider -- The mock provider to use
]=]
function PropertyReflection.setProvider(provider: ReflectionProvider)
    _provider = provider
end

--[=[
    Resets the provider to the default ReflectionService-based one.
]=]
function PropertyReflection.resetProvider()
    _provider = nil
end

--[=[
    Reads all serializable properties from an instance and returns them in
    Rojo's property format (implicit when possible, explicit when needed).

    @param instance Instance -- The instance to read properties from
    @return { [string]: any } -- Property map in Rojo format
]=]
function PropertyReflection.getSerializableProperties(instance: Instance): { [string]: any }
    assert(typeof(instance) == "Instance", "Expected an Instance")

    local provider = _getProvider()
    local propertyInfos = provider:GetSerializableProperties(instance.ClassName)
    local result = {}

    for _, info in propertyInfos do
        -- Skip Name since it's represented by the tree key
        if info.Name == "Name" then
            continue
        end

        -- Skip legacy or internal-only properties
        if SKIP_PROPERTIES[info.Name] then
            continue
        end

        -- Resolve aliased property names. Some internal properties
        -- (e.g. Color3uint8) can't be accessed directly and need
        -- their public API name (e.g. Color) instead.
        local propName = PROPERTY_ALIASES[info.Name] or info.Name

        local success, value = pcall(function()
            return (instance :: any)[propName]
        end)

        if success and value ~= nil then
            result[propName] = _encodeValue(value, info.Type)
        end
    end

    return result
end

--[=[
    Sets a single property on an instance from a Rojo-format property value.

    @param instance Instance -- The instance to modify
    @param name string -- The property name
    @param value any -- The property value in Rojo format
    @return boolean -- Whether the property was set successfully
]=]
function PropertyReflection.setProperty(instance: Instance, name: string, value: any): boolean
    assert(typeof(instance) == "Instance", "Expected an Instance")
    assert(type(name) == "string", "Expected a string property name")

    local decoded = _decodeValue(value)

    local success = pcall(function()
        (instance :: any)[name] = decoded
    end)

    -- ReflectionService reports some properties with lowercase names
    -- (e.g. "size", "shape") that can be read but not set. Retry with
    -- the first letter uppercased to use the API-compatible name.
    if not success then
        local firstChar = string.sub(name, 1, 1)
        local upper = string.upper(firstChar)
        if upper ~= firstChar then
            local pascalName = upper .. string.sub(name, 2)
            success = pcall(function()
                (instance :: any)[pascalName] = decoded
            end)
        end
    end

    return success
end

--[=[
    Encodes a Roblox property value into Rojo's JSON-compatible format. Uses
    implicit format for simple types (string, number, boolean) and explicit
    format for complex types (Vector3, Color3, CFrame, etc).

    @param value any -- The Roblox property value
    @param typeName string -- The reflection type name
    @return any -- The Rojo-format encoded value
]=]
function _encodeValue(value: any, typeName: string): any
    local valueType = typeof(value)

    -- Simple types use implicit format
    if valueType == "string" or valueType == "number" or valueType == "boolean" then
        return value
    end

    -- Complex types use explicit Rojo format
    if valueType == "Vector3" then
        return { Vector3 = { value.X, value.Y, value.Z } }
    elseif valueType == "Vector2" then
        return { Vector2 = { value.X, value.Y } }
    elseif valueType == "Color3" then
        return { Color3 = { value.R, value.G, value.B } }
    elseif valueType == "CFrame" then
        local components = { value:GetComponents() }
        return {
            CFrame = {
                position = { components[1], components[2], components[3] },
                orientation = {
                    { components[4], components[5], components[6] },
                    { components[7], components[8], components[9] },
                    { components[10], components[11], components[12] },
                },
            },
        }
    elseif valueType == "UDim" then
        return { UDim = { value.Scale, value.Offset } }
    elseif valueType == "UDim2" then
        return {
            UDim2 = {
                { value.X.Scale, value.X.Offset },
                { value.Y.Scale, value.Y.Offset },
            },
        }
    elseif valueType == "Rect" then
        return {
            Rect = {
                { value.Min.X, value.Min.Y },
                { value.Max.X, value.Max.Y },
            },
        }
    elseif valueType == "NumberRange" then
        return { NumberRange = { value.Min, value.Max } }
    elseif valueType == "BrickColor" then
        return { BrickColor = value.Number }
    elseif valueType == "EnumItem" then
        return { Enum = value.Value }
    elseif valueType == "NumberSequence" then
        local keypoints = {}
        for _, kp in value.Keypoints do
            table.insert(keypoints, {
                time = kp.Time,
                value = kp.Value,
                envelope = kp.Envelope,
            })
        end
        return { NumberSequence = { keypoints = keypoints } }
    elseif valueType == "ColorSequence" then
        local keypoints = {}
        for _, kp in value.Keypoints do
            table.insert(keypoints, {
                time = kp.Time,
                color = { kp.Value.R, kp.Value.G, kp.Value.B },
            })
        end
        return { ColorSequence = { keypoints = keypoints } }
    elseif valueType == "Font" then
        return {
            Font = {
                family = value.Family,
                weight = value.Weight.Name,
                style = value.Style.Name,
            },
        }
    end

    -- Fallback: try to convert to string
    local success, str = pcall(tostring, value)
    if success then
        return str
    end

    return nil
end

--[=[
    Decodes a Rojo-format property value back into a Roblox value. Handles
    both implicit (plain values) and explicit (typed object) formats.

    @param value any -- The Rojo-format property value
    @return any -- The decoded Roblox value
]=]
function _decodeValue(value: any): any
    -- Simple types pass through
    if type(value) ~= "table" then
        return value
    end

    -- Explicit format: single-key table where key is the type name
    local typeName, typeValue = next(value)
    if typeName == nil then
        return value
    end

    -- Check if there's more than one key (not explicit format)
    if next(value, typeName) ~= nil then
        return value
    end

    if typeName == "Vector3" then
        return Vector3.new(typeValue[1], typeValue[2], typeValue[3])
    elseif typeName == "Vector2" then
        return Vector2.new(typeValue[1], typeValue[2])
    elseif typeName == "Color3" then
        return Color3.new(typeValue[1], typeValue[2], typeValue[3])
    elseif typeName == "CFrame" then
        local pos = typeValue.position
        local ori = typeValue.orientation
        return CFrame.new(
            pos[1],
            pos[2],
            pos[3],
            ori[1][1],
            ori[1][2],
            ori[1][3],
            ori[2][1],
            ori[2][2],
            ori[2][3],
            ori[3][1],
            ori[3][2],
            ori[3][3]
        )
    elseif typeName == "UDim" then
        return UDim.new(typeValue[1], typeValue[2])
    elseif typeName == "UDim2" then
        return UDim2.new(typeValue[1][1], typeValue[1][2], typeValue[2][1], typeValue[2][2])
    elseif typeName == "Rect" then
        return Rect.new(typeValue[1][1], typeValue[1][2], typeValue[2][1], typeValue[2][2])
    elseif typeName == "NumberRange" then
        return NumberRange.new(typeValue[1], typeValue[2])
    elseif typeName == "BrickColor" then
        return BrickColor.new(typeValue)
    elseif typeName == "Enum" then
        return typeValue
    elseif typeName == "NumberSequence" then
        local keypoints = {}
        for _, kp in typeValue.keypoints do
            table.insert(keypoints, NumberSequenceKeypoint.new(kp.time, kp.value, kp.envelope))
        end
        return NumberSequence.new(keypoints)
    elseif typeName == "ColorSequence" then
        local keypoints = {}
        for _, kp in typeValue.keypoints do
            table.insert(
                keypoints,
                ColorSequenceKeypoint.new(kp.time, Color3.new(kp.color[1], kp.color[2], kp.color[3]))
            )
        end
        return ColorSequence.new(keypoints)
    elseif typeName == "Font" then
        local weight = (Enum.FontWeight :: any)[typeValue.weight]
        local style = (Enum.FontStyle :: any)[typeValue.style]
        return Font.new(typeValue.family, weight, style)
    elseif typeName == "Bool" then
        return typeValue
    elseif typeName == "String" or typeName == "ProtectedString" or typeName == "Content" then
        return typeValue
    elseif typeName == "Float32" or typeName == "Float64" or typeName == "Int32" or typeName == "Int64" then
        return typeValue
    end

    return value
end

return PropertyReflection
