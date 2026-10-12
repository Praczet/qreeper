-- triggers/room.lua
-- Room observation: turns MUD output into confirmed room arrivals.
--
-- Flow per room: header line -> observer collects description -> "Obvious exits" line or a
-- prompt finishes it -> memory matches/creates the room -> tracker explains the arrival ->
-- a directed exit is recorded only when a queued move explains it.
--
-- ROOM_PATTERN and the helpers here use Lua patterns, not regexes. The Blightmud triggers
-- at the bottom use `^.*$` only to see every line; the real parsing happens in Lua.

local Whisper = require("whisper")
local Observer = require("observer")
local Tracker = require("tracker")

local RoomTriggers = {}

-- "Room name (n, s, e) ---*---": name, exit list in parentheses, compass decoration.
local ROOM_PATTERN = "^%s*(.-)%s+%(([^%)]+)%)%s+(.+)$"

-- Give up on a description after this many lines; something is not a room.
local MAX_DESCRIPTION_LINES = 30

---Recognise the compass decoration that ends a room header, e.g. `---*---` or `-U-*-D-`.
---@param text string
---@return boolean
local function is_compass(text)
	return text:match("%-[%u%-]*%*[%u%-]*%-") ~= nil
end

---Guess realm, area and level for a room the first time it is seen.
---Only new rooms are touched, so values set by hand are never overwritten.
---@return table|nil `{ source = "name"|"inherited", area }` when an area was assigned.
local function infer_location(memory, room, status, movement)
	if status ~= "new" then
		return nil
	end

	local previous

	if movement.from and movement.from ~= movement.to then
		previous = memory:get_room_location(movement.from)
	end

	-- Inherit realm, if known.
	if previous and previous.realm then
		memory:set_room_location(movement.to, "realm", previous.realm)
	end

	-- Level follows up/down from the previous room; any other move keeps it.
	if previous and previous.level ~= nil then
		local level = previous.level

		if movement.direction == "up" then
			level = level + 1
		elseif movement.direction == "down" then
			level = level - 1
		end

		memory:set_room_location(movement.to, "level", level)
	end

	-- Prefer an explicit "Area: Room" prefix in the room name.
	local area = room.name:match("^%s*(.-)%s*:%s*%S")

	if area then
		memory:set_room_location(movement.to, "area", area)

		return {
			source = "name",
			area = area,
		}
	end

	-- Otherwise inherit the previous room's area.
	if previous and previous.area then
		memory:set_room_location(movement.to, "area", previous.area)

		return {
			source = "inherited",
			area = previous.area,
		}
	end

	return nil
end

---Build the observation for a header: trimmed name, normalised sorted exits, fingerprint.
---@param name string
---@param exits_text string Comma-separated exits from the header.
---@return table
local function parse_room(name, exits_text)
	name = name:match("^%s*(.-)%s*$")

	local exits = {}
	local seen = {}

	for value in exits_text:gmatch("[^,]+") do
		local direction = Tracker.normalize(value:match("^%s*(.-)%s*$"):lower())

		if direction ~= "" and not seen[direction] then
			seen[direction] = true
			table.insert(exits, direction)
		end
	end

	table.sort(exits)

	return {
		name = name,
		exits = exits,
		fingerprint = name .. "|" .. table.concat(exits, ","),
	}
end

---Parse a line as a room header, or return nil if it is not one.
---@param text string
---@return table|nil
local function parse_header(text)
	local name, exits_text, compass = text:match(ROOM_PATTERN)

	if not name or not is_compass(compass) then
		return nil
	end

	return parse_room(name, exits_text)
end

---True for the "Obvious exits" line that ends a room description.
---@param text string
---@return boolean
local function is_exits_summary(text)
	-- "obvious exit" also matches "obvious exits".
	return text:lower():find("obvious exit", 1, true) ~= nil
end

---Companion commentary for an arrival.
local function describe_room(room, status, movement)
	if movement.direction then
		if movement.from and movement.from == movement.to then
			return "Still in " .. room.name .. ". " .. movement.direction .. " was not particularly productive."
		end

		return "We travelled " .. movement.direction .. " and reached " .. room.name .. "."
	end

	if status == "new" then
		return "A new discovery! " .. room.name .. ". I shall remember this one."
	end

	return "Ah, " .. room.name .. ". We've seen this place before."
end

---Register the line and prompt triggers that drive room observation.
---@param qreeper table Lifecycle instance that owns the triggers.
---@param memory table
---@param tracker table
function RoomTriggers.register(qreeper, memory, tracker)
	local observer = Observer.new()

	-- Complete the pending observation: store it, explain the arrival, record the edge.
	local function finish_room()
		local room = observer:finish()

		if not room then
			return
		end

		local ok, id, status = pcall(function()
			return memory:remember_room(room)
		end)

		if not ok then
			tracker:lose_position()
			Whisper.say("My memory falters. " .. tostring(id))
			return
		end

		if not id then
			tracker:lose_position()
			Whisper.say("This place seems familiar, but I cannot quite place it.")
			return
		end

		local movement = tracker:observe_room(id, room.exits)

		local location_ok, location = pcall(function()
			return infer_location(memory, room, status, movement)
		end)

		if not location_ok then
			Whisper.say("My sense of geography is temporarily unreliable.")
			return
		end

		if movement.from and movement.direction and movement.from ~= movement.to then
			local saved, connected = pcall(function()
				return memory:connect_rooms(movement.from, movement.direction, movement.to)
			end)

			if not saved then
				Whisper.say("I remember arriving, but the route escapes me.")
				return
			end

			if not connected then
				Whisper.say("Curious. This passage disagrees with my memories.")
				return
			end
		end

		local message = describe_room(room, status, movement)

		if location and location.source == "name" then
			message = message .. " " .. location.area .. ". At least this place has the decency to introduce itself."
		elseif location and location.source == "inherited" then
			message = message
				.. " This area seems a little hazy."
				.. " I'll call it \""
				.. location.area
				.. '" for now.'
		end

		Whisper.say(message)
	end

	-- Every ordinary output line passes through here.
	qreeper:add_trigger("^.*$", { gag = false }, function(_, line)
		local text = line:line()
		local room = parse_header(text)

		if room then
			-- A new header completes any unfinished previous observation.
			finish_room()
			observer:begin(room)
			return
		end

		if not observer:is_collecting() then
			return
		end

		if is_exits_summary(text) then
			finish_room()
			return
		end

		observer:add_line(text)

		-- Safety limit: don't collect an entire session as one description.
		if #observer.pending.lines >= MAX_DESCRIPTION_LINES then
			observer:cancel()
			tracker:lose_position()

			Whisper.say("This description goes on rather long. " .. "I shall wait for a clearer account.")
		end
	end)

	-- A MUD prompt also ends a description, for rooms without an exits summary line.
	qreeper:add_trigger("^.*$", {
		gag = false,
		prompt = true,
	}, function()
		finish_room()
	end)
end

return RoomTriggers
