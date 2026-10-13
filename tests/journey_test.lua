-- tests/journey_test.lua
-- navigator.lua route finding and journey.lua whispers, with a fake memory and tracker.
-- Run from the plugin directory: lua5.4 tests/journey_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local status_line = ""
local output = {}

blight = {
	status_height = function() end,
	status_line = function(_, text)
		status_line = text
	end,
	output = function(text)
		table.insert(output, text)
	end,
}

local Navigator = require("navigator")
local Journey = require("journey")

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

---True when the last whisper contains `text`.
local function whispered(text)
	return status_line:find(text, 1, true) ~= nil
end

-- A small slice of the real forest, including its one-way and named exits.
local graph = {
	rooms = {},
	exits = {
		{ from = 11, direction = "south", to = 12 },
		{ from = 11, direction = "enter", to = 8 },
		{ from = 8, direction = "out", to = 11 },
		{ from = 12, direction = "north", to = 11 },
		{ from = 12, direction = "south", to = 22 },
		{ from = 12, direction = "east", to = 16 },
		{ from = 16, direction = "south", to = 18 },
		{ from = 18, direction = "west", to = 12 },
		{ from = 22, direction = "northeast", to = 18 },
		{ from = 22, direction = "north", to = 12 },
		{ from = 22, direction = "northwest", to = nil },
		-- One-way: 21 reaches 12, but nothing reaches 21.
		{ from = 21, direction = "east", to = 12 },
	},
}

for _, id in ipairs({ 8, 11, 12, 16, 18, 21, 22 }) do
	graph.rooms[id] = { id = id, name = "Room " .. id }
end

-- Navigator ---------------------------------------------------------------------------------

expect("route 11 -> 18", Navigator.describe(Navigator.route(graph, 11, 18)), "s, e, s")
expect("route through a named exit", Navigator.describe(Navigator.route(graph, 8, 22)), "out, s, s")
expect("already there is an empty route", #Navigator.route(graph, 12, 12), 0)
expect("one-way exits are not reversed", Navigator.route(graph, 12, 21), nil)
expect("unknown room has no route", Navigator.route(graph, 12, 99), nil)
expect("ties break by direction name", Navigator.describe(Navigator.route(graph, 12, 18)), "e, s")

do
	-- Walked down into a new room that lists `up`: `up` is the probable way back.
	local fresh = {
		rooms = { [1] = { id = 1 }, [2] = { id = 2 }, [3] = { id = 3 } },
		exits = {
			{ from = 1, direction = "down", to = 2 },
			{ from = 2, direction = "up", to = nil },
			{ from = 1, direction = "east", to = 3 },
		},
	}
	expect("probable way back is offered", Navigator.describe(Navigator.route(fresh, 2, 3)), "u?, e")

	-- No advertised opposite exit, no guess.
	fresh.exits[2] = { from = 2, direction = "south", to = nil }
	expect("unlisted way back is not guessed", Navigator.route(fresh, 2, 3), nil)

	-- An opposite exit that already leads elsewhere is not guessed either.
	fresh.exits[2] = { from = 2, direction = "up", to = 3 }
	expect("opposite exit leading elsewhere is not guessed", Navigator.route(fresh, 2, 1), nil)
end

do
	-- A walked route beats a probable shortcut unless the shortcut saves enough moves.
	local choice = {
		rooms = { [1] = { id = 1 }, [2] = { id = 2 }, [3] = { id = 3 }, [4] = { id = 4 } },
		exits = {
			{ from = 1, direction = "down", to = 2 },
			{ from = 2, direction = "up", to = nil },
			{ from = 2, direction = "east", to = 3 },
			{ from = 3, direction = "north", to = 1 },
		},
	}
	expect("walked 2 moves beats probable 1", Navigator.describe(Navigator.route(choice, 2, 1)), "e, n")
end

-- Journey -----------------------------------------------------------------------------------

local memory = {
	get_map = function()
		return graph
	end,
}
local tracker = { current_room = 11 }
local journey = Journey.new(memory, tracker)

journey:start(18)
expect("start whispers the route", whispered("To #18: s, e, s."), true)
expect("start prints ids to scrollback", output[#output], "  s → #12, e → #16, s → #18")
expect("journey is active", journey:active(), true)

tracker.current_room = 12
journey:on_arrival()
expect("next room whispers the rest", whispered("To #18 you should follow e, s."), true)

-- Detour: player went south to 22 instead of east.
tracker.current_room = 22
journey:on_arrival()
expect("detour recalculates", whispered("To #18: just ne."), true)

tracker.current_room = 18
journey:on_arrival()
expect("arrival is announced", whispered("arrived at #18"), true)
expect("arrival ends the journey", journey:active(), false)

journey:start(21)
expect("unreachable target is explained", whispered("not a walked path"), true)
expect("unreachable target keeps listening", journey:active(), true)
journey:stop()
expect("stay ends the journey", journey:active(), false)
expect("stay is acknowledged", whispered("we stay"), true)

journey:start(99)
expect("unknown target is refused", journey:active(), false)

tracker.current_room = 11
journey:start(22)
tracker.current_room = nil
journey:on_arrival()
expect("lost position pauses", whispered("lost our bearings"), true)
expect("lost position keeps the journey", journey:active(), true)
tracker.current_room = 12
journey:on_arrival()
expect("recognised room resumes", whispered("To #22: just s."), true)

journey:start(12)
expect("goto current room", whispered("already in #12"), true)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end

print("all journey tests passed")
