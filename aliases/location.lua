-- aliases/location.lua
-- Manual geography for the current room: `qreeper:realm NAME`, `qreeper:area NAME`,
-- `qreeper:level N`. Manual values win; inference only ever fills new rooms.

local Whisper = require("whisper")

local LocationAliases = {}

---@param qreeper table Lifecycle instance that owns the aliases.
---@param memory table
---@param tracker table
function LocationAliases.register(qreeper, memory, tracker)
	-- Write one field on the current room and acknowledge it in character.
	local function set_location(field, value)
		local room_id = tracker.current_room

		if not room_id then
			Whisper.say("I need to know where we are first. " .. "Try looking around.")
			return
		end

		local ok, err = pcall(function()
			memory:set_room_location(room_id, field, value)
		end)

		if not ok then
			Whisper.say("My geographical records are being difficult. " .. tostring(err))
			return
		end

		if field == "realm" then
			Whisper.say("Very well. This realm shall be known as " .. value .. ".")
		elseif field == "area" then
			Whisper.say("Ah, " .. value .. ". A proper name. How reassuring.")
		elseif field == "level" then
			Whisper.say("Level " .. value .. ". Even I can count that high.")
		end
	end

	for _, field in ipairs({ "realm", "area" }) do
		local location_field = field

		qreeper:add_alias("^qreeper:" .. location_field .. "\\s+(.+)$", function(matches)
			local value = matches[2]:match("^%s*(.-)%s*$")

			if value ~= "" then
				set_location(location_field, value)
			end
		end)
	end

	qreeper:add_alias("^qreeper:level\\s+(-?\\d+)$", function(matches)
		local level = tonumber(matches[2])

		if level then
			set_location("level", level)
		end
	end)
end

return LocationAliases
