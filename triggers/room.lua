local Whisper = require("whisper")

local RoomTriggers = {}

local function parse_room(name, exits_text)
	name = name:match("^%s*(.-)%s*$")

	local exits = {}
	local seen = {}

	for value in exits_text:gmatch("[^,]+") do
		local direction = value:match("^%s*(.-)%s*$"):lower()

		if direction ~= "" and not seen[direction] then
			seen[direction] = true
			table.insert(exits, direction)
		end
	end

	-- Canonical ordering for matching.
	table.sort(exits)

	return {
		name = name,
		exits = exits,
		fingerprint = name .. "|" .. table.concat(exits, ","),
	}
end

function RoomTriggers.register(qreeper, memory, tracker)
	qreeper:add_trigger("^\\s*(.+?)\\s+\\(([^()]+)\\)\\s+.*---\\*---", { gag = false }, function(matches, line)
		local room = parse_room(matches[2], matches[3])

		local ok, id, status = pcall(function()
			return memory:remember_room(room)
		end)

		if not ok then
			Whisper.say("My memory falters. " .. tostring(id))
			return
		end

		local movement = tracker:observe_room(id)

		if movement.direction then
			Whisper.say("South, was it? I believe we've arrived at " .. room.name .. ".")
		end

		if status == "ambiguous" then
			Whisper.say("This place seems terribly familiar. " .. "Perhaps too familiar.")
		elseif status == "new" then
			Whisper.say("A new discovery! " .. room.name .. ". I shall remember this one.")
		else
			Whisper.say("Ah, " .. room.name .. ". We've seen this place before.")
		end
	end)
end

return RoomTriggers
