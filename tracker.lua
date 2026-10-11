local Tracker = {}
Tracker.__index = Tracker

local directions = {
	n = "n",
	north = "n",
	s = "s",
	south = "s",
	e = "e",
	east = "e",
	w = "w",
	west = "w",
	u = "u",
	up = "u",
	d = "d",
	down = "d",
	ne = "ne",
	northeast = "ne",
	nw = "nw",
	northwest = "nw",
	se = "se",
	southeast = "se",
	sw = "sw",
	southwest = "sw",
}

function Tracker.new()
	return setmetatable({
		current_room = nil,
		pending_direction = nil,
	}, Tracker)
end

function Tracker:attempt_move(direction)
	self.pending_direction = directions[direction]
end

function Tracker:observe_room(room_id)
	local movement = {
		from = self.current_room,
		to = room_id,
		direction = self.pending_direction,
	}

	self.current_room = room_id
	self.pending_direction = nil

	return movement
end

function Tracker:movement_failed()
	self.pending_direction = nil
end

return Tracker
