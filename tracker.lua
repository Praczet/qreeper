-- tracker.lua
-- Movement tracker: keeps what the player *asked for* apart from where the MUD *put* them.
--
-- Every movement or look command becomes an "intent" in a FIFO queue. Each observed room
-- consumes exactly one intent, oldest first, because the MUD answers commands in order.
-- An intent is evidence of a direction only; the room observation is the evidence of arrival.
--
-- Three guards stop a stale intent from wiring a wrong edge:
--   1. A recognised failure message removes the oldest pending move (see triggers/movement.lua).
--   2. A compass move that the previous room never advertised is discarded as failed.
--   3. Intents older than INTENT_TTL_SECONDS expire; an unrecognised failure cannot linger forever.

local Tracker = {}
Tracker.__index = Tracker

-- Intents this old are assumed to have failed silently.
local INTENT_TTL_SECONDS = 8

-- Hard cap so a stuck session cannot grow the queue without bound.
local MAX_INTENTS = 20

local DIRECTIONS = {
	n = "north",
	north = "north",
	s = "south",
	south = "south",
	e = "east",
	east = "east",
	w = "west",
	west = "west",
	u = "up",
	up = "up",
	d = "down",
	down = "down",
	ne = "northeast",
	northeast = "northeast",
	nw = "northwest",
	northwest = "northwest",
	se = "southeast",
	southeast = "southeast",
	sw = "southwest",
	southwest = "southwest",
}

-- Directions that rooms list in their header. Named exits (enter, out, tutorial) are
-- often unlisted, so they are never rejected for missing from the exit list.
local COMPASS = {
	north = true,
	south = true,
	east = true,
	west = true,
	up = true,
	down = true,
	northeast = true,
	northwest = true,
	southeast = true,
	southwest = true,
}

---Normalise a typed direction (`n`, `ne`, `north`) to its long form; named exits pass through.
---@param direction string
---@return string
function Tracker.normalize(direction)
	return DIRECTIONS[direction] or direction
end

---Create an empty tracker with no known position.
function Tracker.new()
	return setmetatable({
		current_room = nil,
		-- Set of directions advertised by the current room's header, or nil when unknown.
		current_exits = nil,
		-- The room before the current one and the move that explained the arrival (nil for
		-- unexplained arrivals). `qreeper:map-type` splits a map at that exit.
		previous_room = nil,
		arrived_by = nil,
		intents = {},
		-- Called with the advertised exit list after every room observation (see on_exits).
		exits_listener = nil,
	}, Tracker)
end

---Append an intent with a timestamp, trimming the oldest when the queue is full.
---@param intent table
function Tracker:push(intent)
	intent.at = os.time()
	table.insert(self.intents, intent)

	while #self.intents > MAX_INTENTS do
		table.remove(self.intents, 1)
	end
end

---Record that the player sent a movement command. This is not evidence that it worked.
---@param command string
function Tracker:attempt_move(command)
	self:push({
		kind = "move",
		direction = Tracker.normalize(command),
	})
end

---Record that the player asked to look. The resulting room output must not be read as travel.
function Tracker:expect_look()
	self:push({ kind = "look" })
end

---Remove the oldest pending move because the MUD refused it.
---@return table|nil intent The rejected intent, if any.
function Tracker:reject_move()
	for index, intent in ipairs(self.intents) do
		if intent.kind == "move" then
			return table.remove(self.intents, index)
		end
	end

	return nil
end

---Forget the current position and every pending intent, e.g. after an ambiguous room.
function Tracker:lose_position()
	self.current_room = nil
	self.current_exits = nil
	self.previous_room = nil
	self.arrived_by = nil
	self.intents = {}
end

---Drop intents that are too old to explain the next arrival.
---@param now integer
function Tracker:expire(now)
	while self.intents[1] and now - self.intents[1].at > INTENT_TTL_SECONDS do
		table.remove(self.intents, 1)
	end
end

---Take the oldest intent that could explain an arrival, discarding impossible moves.
---@return table|nil
function Tracker:take_intent()
	self:expire(os.time())

	while #self.intents > 0 do
		local intent = table.remove(self.intents, 1)

		if intent.kind ~= "move" then
			return intent
		end

		local unadvertised = COMPASS[intent.direction] and self.current_exits and not self.current_exits[intent.direction]

		if not unadvertised then
			return intent
		end

		-- The previous room had no such exit, so that command failed. Try the next intent.
	end

	return nil
end

---The move that would explain an arrival right now, without consuming anything.
---Mirrors take_intent's rules (expiry, unadvertised compass moves) so memory.lua can use
---the recorded destination of that exit as identity evidence before the arrival is booked.
---@return string|nil direction
function Tracker:peek_direction()
	local now = os.time()

	for _, intent in ipairs(self.intents) do
		if now - intent.at <= INTENT_TTL_SECONDS then
			if intent.kind ~= "move" then
				return nil
			end

			local unadvertised = COMPASS[intent.direction] and self.current_exits and not self.current_exits[intent.direction]

			if not unadvertised then
				return intent.direction
			end
		end
	end

	return nil
end

---Record a confirmed room observation and describe how we got there.
---@param room_id integer
---@param exits string[] Directions advertised by the observed room's header.
---@return table movement `{ from, to, direction }`; direction is nil unless a move explains it.
function Tracker:observe_room(room_id, exits)
	local intent = self:take_intent()

	local movement = {
		from = self.current_room,
		to = room_id,
		direction = intent and intent.kind == "move" and intent.direction or nil,
	}

	local advertised = {}

	for _, direction in ipairs(exits or {}) do
		advertised[direction] = true
	end

	-- A look (same room, no move) keeps the arrival that brought us here.
	if movement.direction or movement.from ~= room_id then
		self.previous_room = movement.from
		self.arrived_by = movement.direction
	end

	self.current_room = room_id
	self.current_exits = advertised

	if self.exits_listener then
		self.exits_listener(exits or {})
	end

	return movement
end

---Call `callback(exits)` with the advertised exits each time a room is observed. One listener;
---a later call replaces it.
---@param callback fun(exits: string[])|nil
function Tracker:on_exits(callback)
	self.exits_listener = callback
end

---Short human-readable description of the pending queue, oldest first.
---@return string
function Tracker:describe_intents()
	if #self.intents == 0 then
		return "none"
	end

	local parts = {}

	for _, intent in ipairs(self.intents) do
		table.insert(parts, intent.kind == "move" and intent.direction or "look")
	end

	return table.concat(parts, ", ")
end

return Tracker
