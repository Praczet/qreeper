-- triggers/room.lua
-- Room observation: turns MUD output into confirmed room arrivals.
--
-- Flow per room: header line -> observer collects description -> "Obvious exits" line ->
-- identity (identity.lua; may wait for the detail lines after the summary when rooms are
-- otherwise identical) -> memory matches/creates the room -> tracker explains the arrival ->
-- a directed exit is recorded only when a queued move explains it -> the QREEP snapshot is
-- republished, whatever the outcome, so the minimap never lags behind the tracker.
--
-- ROOM_PATTERN and the helpers here use Lua patterns, not regexes. The Blightmud triggers
-- at the bottom use `^.*$` only to see every line; the real parsing happens in Lua.

local Whisper = require("whisper")
local Observer = require("observer")
local Tracker = require("tracker")

local RoomTriggers = {}

-- "Room name (n, s, e) ---*---": name, exit list in parentheses, compass decoration. The
-- compass may follow the parenthesis directly when its first letter is a direction label:
-- "(w,n,s,enter)W ---*---".
local ROOM_PATTERN = "^%s*(.-)%s+%(([^%)]+)%)%s*(.+)$"

-- Ornaments some rooms wrap their name in: "-={@ Entrance to the Cathedral @}=-".
local NAME_ORNAMENT = "[%s%-=~%*@<>{}%[%]]"

-- Give up on a description after this many lines; something is not a room.
local MAX_DESCRIPTION_LINES = 30

-- Close an observation's details this long after "Obvious exits" if no prompt arrives.
local DETAILS_TIMEOUT_SECONDS = 1

---Recognise the compass decoration that ends a room header, e.g. `---*---` or `-U-*-D-`.
---@param text string
---@return boolean
local function is_compass(text)
	return text:match("%-[%u%-]*%*[%u%-]*%-") ~= nil
end

---Guess the level for a room the first time it is seen. Only new rooms are touched, so a
---level set by hand is never overwritten. Realm and map belong to the room's map
---(publisher/placement.lua).
local function infer_location(memory, status, movement)
	if status ~= "new" and status ~= "twin" then
		return
	end

	local previous

	if movement.from and movement.from ~= movement.to then
		previous = memory:get_room_location(movement.from)
	end

	memory:set_room_location(movement.to, "level", RoomTriggers.infer_level(previous and previous.level, movement.direction))
end

---Build the observation for a header: trimmed name, normalised sorted exits, fingerprint.
---@param name string
---@param exits_text string Comma-separated exits from the header.
---@return table
local function parse_room(name, exits_text)
	local bare = name:gsub("^" .. NAME_ORNAMENT .. "+", ""):gsub(NAME_ORNAMENT .. "+$", "")
	name = bare ~= "" and bare or name:match("^%s*(.-)%s*$")

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
function RoomTriggers.parse_header(text)
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
	if movement.direction and status == "twin" then
		return "We travelled " .. movement.direction .. ". Another " .. room.name .. ": same name, same exits, different description. Noted separately."
	end

	if movement.direction then
		if movement.from and movement.from == movement.to then
			return "Still in " .. room.name .. ". " .. movement.direction .. " was not particularly productive."
		end

		return "We travelled " .. movement.direction .. " and reached " .. room.name .. "."
	end

	if status == "new" then
		return "A new discovery! " .. room.name .. ". I shall remember this one."
	end

	if status == "twin" then
		return "Another " .. room.name .. ". Same name, same exits, different place. Noted separately."
	end

	return "Ah, " .. room.name .. ". We've seen this place before."
end

---Level for a newly discovered room: `up` adds one to the previous room's level, `down`
---takes one off, anything else keeps it. An unknown previous level (the very first room, an
---unexplained arrival, a room nobody levelled) counts as 0, so every room gets a level and
---the chain never stalls. Levels are relative; `qreeper:level N` corrects them.
---@param previous_level integer|nil
---@param direction string|nil
---@return integer
function RoomTriggers.infer_level(previous_level, direction)
	local level = previous_level or 0

	if direction == "up" then
		return level + 1
	elseif direction == "down" then
		return level - 1
	end

	return level
end

---Level a known room *should* have after a confirmed up/down move, when that disagrees
---with the stored one. Only warns; stored levels are never changed automatically, because a
---manual `qreeper:level` may be the right one and the MUD's stairs may simply be odd.
---Exported for tests.
---@param status string `remember_room` status; new rooms are handled by infer_location.
---@param direction string|nil Confirmed movement direction.
---@param from_level integer|nil
---@param to_level integer|nil
---@return integer|nil expected The level implied by the move, or nil when there is no conflict.
function RoomTriggers.level_conflict(status, direction, from_level, to_level)
	if status ~= "known" or from_level == nil or to_level == nil then
		return nil
	end

	local expected

	if direction == "up" then
		expected = from_level + 1
	elseif direction == "down" then
		expected = from_level - 1
	else
		return nil
	end

	if expected == to_level then
		return nil
	end

	return expected
end

---Register the line and prompt triggers that drive room observation.
---@param qreeper table Lifecycle instance that owns the triggers.
---@param memory table
---@param tracker table
---@param publisher table Snapshot publisher, notified after every finished observation.
---@param journey table Active `qreeper:goto` journey, told about every arrival.
function RoomTriggers.register(qreeper, memory, tracker, publisher, journey)
	local observer = Observer.new()

	-- Store an observation, explain the arrival, record the edge, and whisper about it.
	-- Returns "deferred" when only the details can identify the room and they have not
	-- arrived yet (nothing is changed in that case), otherwise "done".
	local function record_room(room)
		local ok, id, status = pcall(function()
			-- Identity evidence from movement: the room a confirmed move starts from, and
			-- where the exit being taken already leads, if it was walked before.
			local evidence = {}
			local direction = tracker:peek_direction()

			if tracker.current_room and direction then
				evidence.from_id = tracker.current_room
				evidence.direction = direction
				evidence.predicted_id = memory:get_room_exits(tracker.current_room)[direction] or nil
			end

			return memory:remember_room(room, evidence)
		end)

		if ok and status == "need-details" then
			return "deferred"
		end

		if not ok then
			tracker:lose_position()
			Whisper.say("My memory falters. " .. tostring(id))
			return "done"
		end

		if not id then
			tracker:lose_position()
			Whisper.say("This place seems familiar, but I cannot quite place it.")
			return "done"
		end

		observer:mark_recorded(id)

		local movement = tracker:observe_room(id, room.exits)

		local location_ok = pcall(function()
			infer_location(memory, status, movement)
		end)

		if not location_ok then
			Whisper.say("My sense of geography is temporarily unreliable.")
			return "done"
		end

		-- A move that ends where it started is an exit looping back; record it too.
		if movement.from and movement.direction then
			local saved, connected = pcall(function()
				return memory:connect_rooms(movement.from, movement.direction, movement.to)
			end)

			if not saved then
				Whisper.say("I remember arriving, but the route escapes me.")
				return "done"
			end

			if not connected then
				Whisper.say("Curious. This passage disagrees with my memories.")
				return "done"
			end
		end

		local message = describe_room(room, status, movement)

		-- Second-visit sanity check for levels (first visits are set by infer_location).
		if movement.from and movement.from ~= movement.to then
			local level_ok, from_location, to_location = pcall(function()
				return memory:get_room_location(movement.from), memory:get_room_location(movement.to)
			end)

			local expected = level_ok
				and from_location
				and to_location
				and RoomTriggers.level_conflict(status, movement.direction, from_location.level, to_location.level)

			if expected then
				message = message
					.. " Odd: I have this as level "
					.. to_location.level
					.. ", but "
					.. movement.direction
					.. " from level "
					.. from_location.level
					.. " says "
					.. expected
					.. "."
				blight.output(
					string.format(
						"Qreeper level check: #%d is stored as level %d, but %s from #%d (level %d) suggests %d. If %d is right, stand here and type: qreeper:level %d",
						movement.to,
						to_location.level,
						movement.direction,
						movement.from,
						from_location.level,
						expected,
						expected,
						expected
					)
				)
			end
		end

		Whisper.say(message)
		return "done"
	end

	-- After a room is booked: republish, then let the journey speak last so its next steps
	-- are what stays on the status line.
	local function after_arrival()
		publisher:publish()
		journey:on_arrival()
	end

	-- "Obvious exits" seen: identify now if name/exits/description/graph can decide.
	-- Otherwise keep the observation open until its details arrive.
	local function summary_reached()
		observer:summary()
		local room = observer:snapshot()
		room.details = nil

		if record_room(room) == "done" then
			after_arrival()
		end
	end

	-- Close the open observation (prompt, next header, or timeout). A room already booked
	-- only has its details merged; a deferred one is identified now, details included.
	local function finish_room()
		local room = observer:finish()

		if not room then
			return
		end

		if room.recorded_id then
			pcall(function()
				memory:update_details(room.recorded_id, room.details)
			end)
			return
		end

		record_room(room)
		after_arrival()
	end

	-- Every ordinary output line passes through here.
	qreeper:add_trigger("^.*$", { gag = false }, function(_, line)
		local text = line:line()
		local room = RoomTriggers.parse_header(text)

		if room then
			-- A new header completes any unfinished previous observation.
			finish_room()
			observer:begin(room)
			return
		end

		if not observer:is_collecting() then
			return
		end

		if observer:in_details() then
			observer:add_detail(text)
			return
		end

		if is_exits_summary(text) then
			summary_reached()
			return
		end

		observer:add_line(text)

		-- Safety limit: don't collect an entire session as one description.
		if #observer.pending.lines >= MAX_DESCRIPTION_LINES then
			observer:cancel()
			tracker:lose_position()
			publisher:publish()

			Whisper.say("This description goes on rather long. " .. "I shall wait for a clearer account.")
		end
	end)

	-- A MUD prompt ends the details (and the description, for rooms without a summary line).
	qreeper:add_trigger("^.*$", {
		gag = false,
		prompt = true,
	}, function()
		finish_room()
	end)

	-- Fallback when no prompt is recognised: close details a second or so after the summary.
	-- Only deferred rooms (identical lookalikes) actually wait for this.
	qreeper:add_timer(DETAILS_TIMEOUT_SECONDS, function()
		local age = observer:details_age(os.time())

		if age and age >= DETAILS_TIMEOUT_SECONDS then
			finish_room()
		end
	end)
end

return RoomTriggers
