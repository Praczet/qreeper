-- tests/memory_test.lua
-- memory.lua against a throwaway SQLite file. Needs lsqlite3 for Lua 5.4 (luarocks).
-- Run from the plugin directory:
--   LUA_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so;;" lua5.4 tests/memory_test.lua [existing.sqlite]
-- With a path argument it also migrates that file, so pass a *copy*, never the live world.

package.path = "./?.lua;" .. package.path

local sqlite3 = require("lsqlite3")
local Memory = require("memory")

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

---Count rows returned by a single-value query.
local function scalar(memory, sql)
	for value in memory.db:urows(sql) do
		return value
	end
end

local path = os.tmpname()
os.remove(path)

do
	local memory = Memory.new(path)
	memory:initialize()
	expect("fresh database migrates to latest", memory:schema_version(), Memory.SCHEMA_VERSION)

	memory:initialize()
	expect("initialize is rerunnable", memory:schema_version(), Memory.SCHEMA_VERSION)

	local columns = {}
	for row in memory.db:nrows("PRAGMA table_info(rooms)") do
		columns[row.name] = true
	end
	expect("rooms.area is gone", columns.area, nil)
	expect("rooms.realm is gone", columns.realm, nil)
	expect("rooms.map_id exists", columns.map_id, true)
	expect("default map types", table.concat(memory:get_map_types(), ","), "building,cave,outdoor")
	expect("adding a type", memory:add_map_type("Sewer"), true)
	expect("types are case-insensitive", memory:add_map_type("SEWER"), false)
	expect("find normalises case", memory:find_map_type("Sewer"), "sewer")
	expect("unknown type", memory:find_map_type("castle"), nil)

	local room = {
		name = "Newbie Tower: Forest",
		exits = { "east", "north" },
		fingerprint = "Newbie Tower: Forest|east,north",
		description = "Trees.",
	}

	local id, status = memory:remember_room(room)
	expect("first sighting is new", status, "new")
	expect("advertised exits are stored", scalar(memory, "SELECT COUNT(*) FROM exits"), 2)

	local again, again_status = memory:remember_room(room)
	expect("second sighting is the same room", again, id)
	expect("second sighting is known", again_status, "known")
	expect("exits are not duplicated", scalar(memory, "SELECT COUNT(*) FROM exits"), 2)

	local other = memory:remember_room({
		name = "Clearing",
		exits = { "south" },
		fingerprint = "Clearing|south",
		description = "",
	})

	expect("unknown exit can be connected", memory:connect_rooms(id, "north", other), true)
	expect("same destination confirms", memory:connect_rooms(id, "north", other), true)
	expect("different destination is refused", memory:connect_rooms(id, "north", id), false)

	-- The way back: Clearing advertises `south`, unexplored, so walking north guesses it.
	expect("way back is guessed", memory:guess_way_back(id, "north", other), true)
	expect("guessed way back is in the graph", memory:get_room(other).exits[1].to, id)
	expect("guessed way back is marked", memory:get_room(other).exits[1].guessed, true)
	expect("guessed way back is no identity evidence", memory:get_room_exits(other).south, false)
	expect("named exits have no way back", memory:guess_way_back(id, "cave", other), false)
	expect("a known way back is not guessed over", memory:guess_way_back(other, "north", id), false)
	expect("walking overwrites a guess", memory:connect_rooms(other, "south", other), true)
	expect("walked exit is no longer guessed", memory:get_room(other).exits[1].guessed, false)
	expect("walked exit is evidence", memory:get_room_exits(other).south, other)
	expect("a walked exit is not overwritten again", memory:connect_rooms(other, "south", id), false)
	memory.db:exec("UPDATE exits SET destination_id = NULL WHERE room_id = " .. other)

	-- Marks: flag on the room, in the graph, reversible.
	expect("fresh room is unmarked", memory:get_map().rooms[id].marked, false)
	expect("marking a room", memory:set_marked(id, true), true)
	expect("marked room in the graph", memory:get_map().rooms[id].marked, true)
	expect("unmarking a room", memory:set_marked(id, false), true)
	expect("unmarked again", memory:get_map().rooms[id].marked, false)
	expect("marking a missing room", memory:set_marked(99999, true), false)

	-- expected_cell: compass offset from a placed room, nil for unplaced or named exits.
	memory.db:exec("UPDATE rooms SET x = 4, y = 2, z = 0 WHERE id = " .. id)
	local cell = memory:expected_cell(id, "east")
	expect("expected cell east", cell and (cell.x .. "," .. cell.y .. "," .. cell.z), "5,2,0")
	expect("no expected cell for named exits", memory:expected_cell(id, "cave"), nil)
	expect("no expected cell when unplaced", memory:expected_cell(other, "east"), nil)
	memory.db:exec("UPDATE rooms SET x = NULL, y = NULL, z = NULL WHERE id = " .. id)

	local where = memory:get_room(id)
	expect("get_room name", where.name, "Newbie Tower: Forest")
	expect("get_room has no map yet", where.map_id, nil)
	expect("get_room lists exits", #where.exits, 2)
	expect("get_room exits are sorted", where.exits[2].direction, "north")
	expect("get_room exit destination", where.exits[2].to, other)
	expect("get_room unknown room", memory:get_room(9999), nil)

	local ok = pcall(function()
		memory:transaction(function()
			memory:add_note(id, "should vanish")
			error("boom")
		end)
	end)
	expect("failed transaction raises", ok, false)
	expect("failed transaction rolls back", scalar(memory, "SELECT COUNT(*) FROM notes"), 0)

	memory:close()
end

do
	-- A database from a newer plugin must not be "migrated" backwards.
	local db = sqlite3.open(path)
	db:exec("PRAGMA user_version = 99")
	db:close()

	local memory = Memory.new(path)
	local ok, err = pcall(function()
		memory:initialize()
	end)
	expect("newer schema is refused", ok, false)
	expect("refusal names the version", tostring(err):find("v99", 1, true) ~= nil, true)
	memory:close()
end

os.remove(path)

-- guess_by_grid: unwalked links between neighbouring cells of a regular grid map.
do
	local grid_path = os.tmpname()
	os.remove(grid_path)

	local memory = Memory.new(grid_path)
	memory:initialize()
	memory.db:exec("INSERT INTO maps (id, name) VALUES (1, 'Grid')")

	-- a(0,0) east-> b(1,0) walked; a southeast / c(1,1) northwest unwalked; b south / c north
	-- unwalked; d(2,0) has no west, so b's east stays unknown.
	local function add(name, x, y, exits)
		local id = memory:remember_room({ name = name, exits = exits, fingerprint = name, description = "" })
		memory.db:exec(string.format("UPDATE rooms SET map_id = 1, x = %d, y = %d, z = 0 WHERE id = %d", x, y, id))
		return id
	end

	local a = add("A", 0, 0, { "east", "southeast" })
	local b = add("B", 1, 0, { "west", "south", "east" })
	local c = add("C", 1, 1, { "north", "northwest" })
	local d = add("D", 2, 0, { "north" })
	memory:connect_rooms(a, "east", b)
	memory:connect_rooms(b, "west", a)

	local filled, misfits = memory:guess_by_grid(1)
	expect("grid fills both pairs", filled, 2)
	expect("grid has no misfits", #misfits, 0)
	expect("diagonal is guessed", memory:get_room(a).exits[2].to, c)
	expect("diagonal is marked guessed", memory:get_room(a).exits[2].guessed, true)
	expect("way back is guessed too", memory:get_room_exits(c).north, false)
	expect("one-sided link stays unknown", scalar(memory, "SELECT destination_id FROM exits WHERE room_id = " .. b .. " AND direction = 'east'"), nil)
	expect("d is untouched", scalar(memory, "SELECT COUNT(*) FROM exits WHERE room_id = " .. d .. " AND destination_id IS NOT NULL"), 0)
	expect("walked exit stays walked", memory:get_room(a).exits[1].guessed, false)
	expect("rerun fills nothing new", (memory:guess_by_grid(1)), 0)

	-- A walked exit landing off its cell makes the grid untrustworthy: nothing is written.
	memory.db:exec("UPDATE exits SET destination_id = NULL, guessed = 0 WHERE guessed = 1")
	memory.db:exec(string.format("UPDATE rooms SET x = 5 WHERE id = %d", b))
	local refused, found = memory:guess_by_grid(1)
	expect("misfit map is refused", refused, nil)
	expect("misfits are reported", #found, 2)
	expect("refused map is unchanged", scalar(memory, "SELECT COUNT(*) FROM exits WHERE guessed = 1"), 0)

	memory:close()
	os.remove(grid_path)
end

if arg[1] then
	-- Adopt an existing pre-versioning database copy without losing anything.
	local memory = Memory.new(arg[1])
	local before = scalar(memory, "SELECT COUNT(*) FROM rooms") .. "/" .. scalar(memory, "SELECT COUNT(*) FROM exits")
	memory:initialize()
	local after = scalar(memory, "SELECT COUNT(*) FROM rooms") .. "/" .. scalar(memory, "SELECT COUNT(*) FROM exits")
	expect("existing copy reaches latest", memory:schema_version(), Memory.SCHEMA_VERSION)
	expect("existing copy keeps rooms/exits", after, before)
	memory:close()
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end

print("all memory tests passed")
