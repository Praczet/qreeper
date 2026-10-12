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
	expect("fresh database migrates to v1", memory:schema_version(), 1)

	memory:initialize()
	expect("initialize is rerunnable", memory:schema_version(), 1)

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
	expect("existing copy reaches v1", memory:schema_version(), 1)
	expect("existing copy keeps rooms/exits", after, before)
	memory:close()
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end

print("all memory tests passed")
