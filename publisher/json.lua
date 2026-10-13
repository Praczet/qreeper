-- publisher/json.lua
-- Minimal JSON encoder for the QREEP snapshot.
--
-- Blightmud ships `json.encode`, but its docs don't say how an empty Lua table or a missing
-- value is encoded. The QREEP consumer rejects a snapshot whose `rooms` is not an array, so
-- this encoder makes the intent explicit instead of guessing:
--   Json.array(t)  -> JSON array (empty stays `[]`)
--   Json.null      -> JSON null
--   other tables   -> JSON object, keys sorted for stable output

local Json = {}

local ARRAY = {}

-- Sentinel for an explicit JSON null; Lua tables cannot hold nil.
Json.null = setmetatable({}, {
	__tostring = function()
		return "null"
	end,
})

---Mark a Lua sequence as a JSON array.
---@param items table|nil
---@return table
function Json.array(items)
	return setmetatable(items or {}, ARRAY)
end

local ESCAPES = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

---Quote a string; control characters become \u escapes, UTF-8 passes through.
---@param value string
---@return string
local function encode_string(value)
	return '"'
		.. value:gsub('[%c"\\]', function(char)
			return ESCAPES[char] or string.format("\\u%04x", char:byte())
		end)
		.. '"'
end

---Integers print as integers; non-finite numbers have no JSON form and become null.
---@param value number
---@return string
local function encode_number(value)
	if value ~= value or value == math.huge or value == -math.huge then
		return "null"
	end

	if math.type and math.type(value) == "integer" then
		return string.format("%d", value)
	end

	if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
		return string.format("%d", value)
	end

	return string.format("%.14g", value)
end

---Encode a Lua value as JSON text.
---@param value any
---@return string
function Json.encode(value)
	local kind = type(value)

	if value == nil or value == Json.null then
		return "null"
	elseif kind == "boolean" then
		return value and "true" or "false"
	elseif kind == "number" then
		return encode_number(value)
	elseif kind == "string" then
		return encode_string(value)
	elseif kind ~= "table" then
		error("Cannot encode " .. kind .. " as JSON")
	end

	local parts = {}

	if getmetatable(value) == ARRAY then
		for index = 1, #value do
			parts[index] = Json.encode(value[index])
		end

		return "[" .. table.concat(parts, ",") .. "]"
	end

	local keys = {}

	for key in pairs(value) do
		assert(type(key) == "string", "JSON object keys must be strings")
		table.insert(keys, key)
	end

	table.sort(keys)

	for _, key in ipairs(keys) do
		table.insert(parts, encode_string(key) .. ":" .. Json.encode(value[key]))
	end

	return "{" .. table.concat(parts, ",") .. "}"
end

return Json
