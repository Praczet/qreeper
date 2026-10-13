-- aliases/rooms.lua
-- Room catalogue: `qreeper:rooms`, `qreeper:rooms realm|map|level`, and
-- `qreeper:rooms realm|map|level VALUE` to filter. Output goes to scrollback.
-- Realm and map come from the room's map (see aliases/location.lua).

local Whisper = require("whisper")

local RoomsAliases = {}

-- Match the muted gold note style used by qreeper:map.
local NOTE_COLOR = "\27[2;33m"
local RESET = "\27[0m"

local FIELDS = {
	realm = true,
	map = true,
	level = true,
}

---Strip leading and trailing whitespace.
local function trim(value)
	return value:match("^%s*(.-)%s*$")
end

---Display label for a room's grouping field; missing values become "Unknown".
local function label(room, field)
	local value = room[field]
	if value == nil or value == "" then
		return "Unknown"
	end
	if field == "level" then
		return "Level " .. tostring(value)
	end
	return tostring(value)
end

---Print one catalogue line plus its latest note.
local function display_room(room, latest_notes)
	blight.output(string.format("  #%03d  %s", room.id, room.name))

	local note = latest_notes[room.id]
	if note and note ~= "" then
		blight.output(NOTE_COLOR .. "       Note: " .. note .. RESET)
	end
end

---Print rooms as one list under a title.
local function display_flat(rooms, title, latest_notes)
	blight.output(title)
	blight.output("")
	for _, room in ipairs(rooms) do
		display_room(room, latest_notes)
	end
end

---Print rooms grouped by `field`, "Unknown" last, levels in numeric order.
local function display_grouped(rooms, field, latest_notes)
	local groups = {}
	local keys = {}

	for _, room in ipairs(rooms) do
		local key = label(room, field)
		if not groups[key] then
			groups[key] = {}
			table.insert(keys, key)
		end
		table.insert(groups[key], room)
	end

	table.sort(keys, function(a, b)
		if a == "Unknown" then
			return false
		elseif b == "Unknown" then
			return true
		end
		if field == "level" then
			local na = tonumber(a:match("^Level (.+)$"))
			local nb = tonumber(b:match("^Level (.+)$"))
			if na and nb then
				return na < nb
			end
		end
		return a:lower() < b:lower()
	end)

	blight.output("Qreeper's catalogue — grouped by " .. field)
	for _, key in ipairs(keys) do
		local entries = groups[key]
		blight.output("")
		blight.output(string.format("%s (%d rooms)", key, #entries))
		for _, room in ipairs(entries) do
			display_room(room, latest_notes)
		end
	end
end

---Load the catalogue and print it flat, grouped, or filtered by an exact field value.
local function list_rooms(memory, field, filter)
	local ok, data = pcall(function()
		return {
			rooms = memory:get_rooms(),
			latest_notes = memory:get_latest_notes(),
		}
	end)

	if not ok then
		Whisper.say("My catalogue appears to have misplaced itself.")
		blight.output("Qreeper rooms error: " .. tostring(data))
		return
	end

	local rooms = data.rooms
	local latest_notes = data.latest_notes

	if #rooms == 0 then
		Whisper.say("Not a single room recorded. We should probably go somewhere.")
		return
	end

	if not field then
		display_flat(rooms, "Qreeper's catalogue — known rooms", latest_notes)
		Whisper.say(#rooms .. " rooms catalogued. And you still manage to get lost.")
		return
	end

	if not filter then
		display_grouped(rooms, field, latest_notes)
		Whisper.say(#rooms .. " rooms catalogued by " .. field .. ".")
		return
	end

	filter = trim(filter)
	if filter == "" then
		Whisper.say("A place needs a name, even a suspicious one.")
		return
	end

	local selected = {}
	for _, room in ipairs(rooms) do
		local value = room[field]
		if value ~= nil and tostring(value):lower() == filter:lower() then
			table.insert(selected, room)
		end
	end

	if #selected == 0 then
		Whisper.say("No rooms found for " .. field .. " '" .. filter .. "'.")
		return
	end

	display_flat(selected, "Qreeper's catalogue — " .. field .. ": " .. filter, latest_notes)
	Whisper.say(#selected .. " rooms found. Remarkably organized, aren't we?")
end

---@param qreeper table Lifecycle instance that owns the aliases.
---@param memory table
function RoomsAliases.register(qreeper, memory)
	-- Separate aliases avoid optional capture ambiguity.
	qreeper:add_alias("^qreeper:rooms$", function()
		list_rooms(memory)
	end)

	qreeper:add_alias("^qreeper:rooms\\s+(realm|map|level)$", function(matches)
		local field = matches[2]
		if FIELDS[field] then
			list_rooms(memory, field)
		end
	end)

	qreeper:add_alias("^qreeper:rooms\\s+(realm|map|level)\\s+(.+)$", function(matches)
		local field = matches[2]
		if FIELDS[field] then
			list_rooms(memory, field, matches[3])
		end
	end)
end

return RoomsAliases
