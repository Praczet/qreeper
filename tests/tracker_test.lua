-- tests/tracker_test.lua
-- Pure-Lua tests for tracker.lua; no Blightmud or SQLite needed.
-- Run from the plugin directory: lua tests/tracker_test.lua

package.path = "./?.lua;" .. package.path

local Tracker = require("tracker")

local failures = 0

---Assert equality and report the case name on failure.
local function expect(name, actual, expected)
	if actual ~= expected then
		failures = failures + 1
		print(string.format("FAIL %s: expected %s, got %s", name, tostring(expected), tostring(actual)))
	else
		print("ok   " .. name)
	end
end

---Tracker already standing in `room_id` with the given advertised exits.
local function tracker_in(room_id, exits)
	local tracker = Tracker.new()
	tracker:observe_room(room_id, exits)
	return tracker
end

do
	-- The exits listener sees every observation's advertised exits.
	local tracker = Tracker.new()
	local seen
	tracker:on_exits(function(exits)
		seen = table.concat(exits, ",")
	end)
	tracker:observe_room(1, { "west", "stables" })
	expect("exits listener is called", seen, "west,stables")
end

do
	-- Rapid "n" then "e": each arrival takes its own intent, in order.
	local tracker = tracker_in(1, { "north" })
	tracker:attempt_move("n")
	tracker:attempt_move("e")
	expect("rapid first arrival is north", tracker:observe_room(2, { "east", "south" }).direction, "north")
	expect("rapid second arrival is east", tracker:observe_room(3, { "west" }).direction, "east")
end

do
	-- The recorded `11 north -> 8` bug: north failed silently in a room without north.
	local tracker = tracker_in(11, { "enter", "south" })
	tracker:attempt_move("n")
	tracker:attempt_move("enter")
	expect("unadvertised north is discarded", tracker:observe_room(8, { "out" }).direction, "enter")
end

do
	-- A recognised failure message removes the move; the next arrival is unexplained.
	local tracker = tracker_in(1, { "north" })
	tracker:attempt_move("n")
	tracker:reject_move()
	expect("rejected move leaves no direction", tracker:observe_room(5, {}).direction, nil)
end

do
	-- Look output is an observation, not travel.
	local tracker = tracker_in(1, { "north" })
	tracker:expect_look()
	expect("look gives no direction", tracker:observe_room(1, { "north" }).direction, nil)
end

do
	-- Move then look: first room is the move, second is the look.
	local tracker = tracker_in(1, { "north" })
	tracker:attempt_move("north")
	tracker:expect_look()
	expect("move before look", tracker:observe_room(2, { "south" }).direction, "north")
	expect("look after move", tracker:observe_room(2, { "south" }).direction, nil)
end

do
	-- Reject skips a queued look and removes the oldest move.
	local tracker = tracker_in(1, { "north", "east" })
	tracker:expect_look()
	tracker:attempt_move("n")
	tracker:attempt_move("e")
	tracker:reject_move()
	expect("look survives reject", tracker:observe_room(1, { "north", "east" }).direction, nil)
	expect("second move survives reject", tracker:observe_room(3, { "west" }).direction, "east")
end

do
	-- Arrivals with nothing queued (teleport, follow, unaliased command) record no edge.
	local tracker = tracker_in(1, { "north" })
	local movement = tracker:observe_room(9, {})
	expect("unexplained arrival has no direction", movement.direction, nil)
	expect("unexplained arrival still updates position", tracker.current_room, 9)
end

do
	-- Named exits are allowed even when the header does not list them.
	local tracker = tracker_in(3, { "north", "south" })
	tracker:attempt_move("tutorial")
	expect("unlisted named exit is kept", tracker:observe_room(30, {}).direction, "tutorial")
end

do
	-- Old intents expire instead of explaining a much later arrival.
	local real_time = os.time
	local now = 1000
	os.time = function()
		return now
	end

	local tracker = tracker_in(1, { "north" })
	tracker:attempt_move("n")
	now = now + 60
	expect("expired intent is ignored", tracker:observe_room(2, {}).direction, nil)

	os.time = real_time
end

do
	-- Losing position clears the queue as well.
	local tracker = tracker_in(1, { "north" })
	tracker:attempt_move("n")
	tracker:lose_position()
	expect("lost position has no room", tracker.current_room, nil)
	expect("lost position has no intents", tracker:describe_intents(), "none")
end

do
	-- The way in is remembered for qreeper:map-type, and a look does not erase it.
	local tracker = Tracker.new()
	tracker:observe_room(1, { "north" })
	tracker:attempt_move("n")
	tracker:observe_room(2, { "south" })
	tracker:expect_look()
	tracker:observe_room(2, { "south" })

	expect("previous room survives a look", tracker.previous_room, 1)
	expect("arrival direction survives a look", tracker.arrived_by, "north")
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end

print("all tracker tests passed")
