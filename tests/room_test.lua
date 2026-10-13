-- tests/room_test.lua
-- Pure checks for triggers/room.lua helpers. Run from the plugin directory:
--   lua5.4 tests/room_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local RoomTriggers = require("triggers.room")

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

local parse = RoomTriggers.parse_header
local cathedral = parse("-={@ Entrance to the Cathedral of All Gods @}=- (w,n,s,enter)W ---*---")
expect("compass glued to the exits is a header", cathedral ~= nil, true)
expect("name ornaments are stripped", cathedral and cathedral.name, "Entrance to the Cathedral of All Gods")
expect("glued header keeps its exits", cathedral and table.concat(cathedral.exits, ","), "enter,north,south,west")
local road = parse("Woodland Road (e,n,s,nw)                     ---*--- E")
expect("plain header still parses", road and road.name, "Woodland Road")
expect("plain header exits", road and table.concat(road.exits, ","), "east,north,northwest,south")
expect("apostrophes survive", parse("Crafter's Lane (e,w) ---*---").name, "Crafter's Lane")
expect("prose is not a header", parse("Merribeth says: If you have any questions (please) ask."), nil)

local infer = RoomTriggers.infer_level
expect("up adds a level", infer(2, "up"), 3)
expect("down takes one off", infer(0, "down"), -1)
expect("other moves keep the level", infer(-1, "north"), -1)
expect("first room is level 0", infer(nil, nil), 0)
expect("unknown previous counts as 0", infer(nil, "up"), 1)

local conflict = RoomTriggers.level_conflict

expect("consistent down is quiet", conflict("known", "down", 1, 0), nil)
expect("consistent up is quiet", conflict("known", "up", 0, 1), nil)
expect("wrong level after down", conflict("known", "down", 1, 1), 0)
expect("wrong level after up", conflict("known", "up", -1, 2), 0)
expect("new rooms are infer_location's job", conflict("new", "down", 1, 5), nil)
expect("other directions are not checked", conflict("known", "north", 1, 3), nil)
expect("unknown levels are not checked", conflict("known", "down", nil, 3), nil)
expect("missing target level is not checked", conflict("known", "up", 2, nil), nil)

do
	-- Named exits outside the fixed list get a per-room alias; compass and fixed ones don't.
	local MovementAliases = require("aliases.movement")
	expect("room exit pattern", MovementAliases.room_exit_pattern({ "west", "enter", "north", "stables" }), "^(stables)$")
	expect("no extra exits, no alias", MovementAliases.room_exit_pattern({ "south", "gate", "u" }), nil)
	expect("several sorted, deduplicated", MovementAliases.room_exit_pattern({ "stables", "Portal", "stables" }), "^(portal|stables)$")
	expect("punctuation escaped", MovementAliases.room_exit_pattern({ "hole.1" }), "^(hole\\.1)$")
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end

print("all room tests passed")
