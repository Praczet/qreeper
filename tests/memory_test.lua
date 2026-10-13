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
