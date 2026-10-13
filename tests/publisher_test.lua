-- tests/publisher_test.lua
-- JSON encoding, first-time placement and the full QREEP snapshot, against a throwaway DB.
-- Run from the plugin directory:
--   LUA_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so;;" lua5.4 tests/publisher_test.lua [out.json]
-- With a path argument the built snapshot is also written there, e.g. to feed QREEP's
-- validator or a running QREEP via QREEP_QREEPER_MAP_PATH.

package.path = "./?.lua;./?/init.lua;" .. package.path

blight = {
	output = function(text)
		print("  output: " .. text)
	end,
}

local Json = require("publisher.json")
local Placement = require("publisher.placement")
local Memory = require("memory")
local Publisher = require("publisher")

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

-- JSON ------------------------------------------------------------------------------------

expect("empty array stays an array", Json.encode(Json.array()), "[]")
expect("empty object", Json.encode({}), "{}")
expect("null sentinel", Json.encode({ a = Json.null }), '{"a":null}')
expect("keys are sorted", Json.encode({ b = 1, a = 2 }), '{"a":2,"b":1}')
expect("integers stay integers", Json.encode(Json.array({ 1, -2, 3.0 })), "[1,-2,3]")
expect("strings are escaped", Json.encode('a"b\\c\nd\1'), '"a\\"b\\\\c\\nd\\u0001"')
expect("utf-8 passes through", Json.encode("Kraków"), '"Kraków"')

-- Placement -------------------------------------------------------------------------------

---Small graph helper: rooms by id with optional stored positions `{ x, y, z, map_id }`,
---exits as given.
local function graph(rooms, exits)
	local result = { rooms = {}, exits = exits }

	for id, position in pairs(rooms) do
		result.rooms[id] = position == true and { id = id }
			or { id = id, x = position[1], y = position[2], z = position[3], map_id = position[4] }
	end

	return result
end

---Index placements by id.
local function by_id(placements)
	local index = {}

	for _, placement in ipairs(placements) do
		index[placement.id] = placement
	end

	return index
end

do
	-- Fresh component seeded from the current room.
	local placed = by_id(Placement.place(graph({ [1] = true, [2] = true, [3] = true }, {
		{ from = 1, direction = "north", to = 2 },
		{ from = 2, direction = "up", to = 3 },
	}), 1))

	expect("seed is at origin", placed[1] and placed[1].x .. "," .. placed[1].y .. "," .. placed[1].z, "0,0,0")
	expect("north is -y", placed[2] and placed[2].y, -1)
	expect("up is +z", placed[3] and placed[3].z, 1)
end

do
	-- Stored rooms never move; a new neighbour attaches to them.
	local placements = Placement.place(graph({ [1] = { 5, 5, 0 }, [2] = true }, {
		{ from = 1, direction = "east", to = 2 },
	}), 2)

	expect("only the new room is placed", #placements, 1)
	expect("new room attaches east of the stored one", placements[1] and placements[1].x, 6)
end

do
	-- Reverse geometry places a room even when only its own exit was recorded.
	local placed = by_id(Placement.place(graph({ [1] = { 0, 0, 0 }, [2] = true }, {
		{ from = 2, direction = "south", to = 1 },
	}), nil))

	expect("room placed from its own exit", placed[2] and placed[2].y, -1)
end

do
	-- Collision: room 3 wants the cell east of 1, which 2 already holds. It goes further
	-- along the same direction instead of vanishing, and its exit becomes irregular.
	local placed = by_id(Placement.place(graph({ [1] = { 0, 0, 0, 1 }, [2] = { 1, 0, 0, 1 }, [3] = true }, {
		{ from = 1, direction = "east", to = 3 },
	}), 3))

	expect("colliding room is displaced, not dropped", placed[3] ~= nil, true)
	expect("displaced along its direction", placed[3] and placed[3].x .. "," .. placed[3].y, "2,0")
	expect("displaced exit is irregular", Placement.geometry({ from = 1, direction = "east", to = 3 }, {
		[1] = { x = 0, y = 0, z = 0 },
		[3] = placed[3],
	}), "irregular")
end

do
	-- The real 115/117/118/119 knot: 119 must appear, and not on top of 117.
	local knot = graph({ [115] = true, [117] = true, [118] = true, [119] = true }, {
		{ from = 115, direction = "west", to = 117 },
		{ from = 117, direction = "east", to = 115 },
		{ from = 115, direction = "southwest", to = 118 },
		{ from = 118, direction = "northeast", to = 115 },
		{ from = 118, direction = "north", to = 119 },
		{ from = 119, direction = "south", to = 118 },
	})
	local placed = by_id(Placement.place(knot, 115))

	expect("119 is placed", placed[119] ~= nil, true)
	expect("119 does not share 117's cell", placed[119] and placed[117] and (placed[119].x .. "," .. placed[119].y) ~= (placed[117].x .. "," .. placed[117].y), true)
end

do
	-- A second component is laid out east of the first instead of on top of it.
	local placed = by_id(Placement.place(graph({ [1] = { 0, 0, 0 }, [2] = { 1, 0, 0 }, [10] = true, [11] = true }, {
		{ from = 1, direction = "east", to = 2 },
		{ from = 10, direction = "west", to = 11 },
		{ from = 2, direction = "enter", to = 10 },
	}), 10))

	expect("new component starts east of the old one", placed[11] and placed[11].x, 4)
	expect("new component keeps its shape", placed[10] and placed[10].x, 5)
end

do
	-- Same level, different path height: must not share a cell. Room 2 is level 1 reached by
	-- `north` (stairs), room 3 is level 0 reached by `down` from 2, room 4 is level 0 next to 1.
	local stairs = graph({ [1] = true, [2] = true, [3] = true, [4] = true }, {
		{ from = 1, direction = "north", to = 2 },
		{ from = 2, direction = "down", to = 3 },
		{ from = 1, direction = "east", to = 4 },
		{ from = 4, direction = "north", to = 3 },
	})
	stairs.rooms[1].level, stairs.rooms[2].level, stairs.rooms[3].level, stairs.rooms[4].level = 0, 1, 0, 0

	local placed = by_id(Placement.place(stairs, 1))
	local seen, overlap = {}, false
	for id, position in pairs(placed) do
		local key = position.x .. ":" .. position.y .. ":" .. stairs.rooms[id].level
		overlap = overlap or seen[key] ~= nil
		seen[key] = id
	end

	expect("z follows stored level", placed[2] and placed[2].z, 1)
	expect("down from level 1 lands on z 0", placed[3] and placed[3].z, 0)
	expect("no two rooms share a cell on one level", overlap, false)
	expect("level-changing north is irregular", Placement.geometry({ from = 1, direction = "north", to = 2 }, placed), "irregular")
end

do
	-- Components the player is not in are not guessed.
	local placements = Placement.place(graph({ [1] = true, [2] = true }, {
		{ from = 1, direction = "east", to = 2 },
	}), nil)

	expect("no current room, no seed", #placements, 0)
end

-- Maps ----------------------------------------------------------------------------------

do
	-- Street 1-2 is placed in map 7. Walking `enter` from 2 into 10 (with 11 west of it)
	-- starts a new map at 10; 3, east of 2 by compass, joins the street's map.
	local placements, maps = Placement.place(graph({ [1] = { 0, 0, 0, 7 }, [2] = { 1, 0, 0, 7 }, [3] = true, [10] = true, [11] = true }, {
		{ from = 1, direction = "east", to = 2 },
		{ from = 2, direction = "east", to = 3 },
		{ from = 2, direction = "enter", to = 10 },
		{ from = 10, direction = "west", to = 11 },
	}), 10)
	local placed = by_id(placements)

	expect("compass neighbour joins its map", placed[3] and placed[3].map, 7)
	expect("one new map behind the portal", #maps, 1)
	expect("portal target is the entrance", maps[1] and maps[1].entrance, 10)
	expect("interior shares the new map", placed[11] and placed[11].map, maps[1] and maps[1].key)
	expect("entrance is in the new map", placed[10] and placed[10].map, maps[1] and maps[1].key)
end

do
	-- Cells only collide inside one map: 3 may take (1, 0) in map 2 although map 1 holds it.
	local placed = by_id(Placement.place(graph({ [1] = { 1, 0, 0, 1 }, [2] = { 0, 0, 0, 2 }, [3] = true }, {
		{ from = 2, direction = "east", to = 3 },
	}), 3))

	expect("same cell in another map is free", placed[3] and placed[3].x .. "," .. placed[3].y, "1,0")
end

do
	-- Floors of a building stay in its map: `up` keeps the map, only z changes.
	local placed = by_id(Placement.place(graph({ [1] = { 0, 0, 0, 4 }, [2] = true }, {
		{ from = 1, direction = "up", to = 2 },
	}), 2))

	expect("upstairs stays in the building's map", placed[2] and placed[2].map, 4)
	expect("upstairs is one floor up", placed[2] and placed[2].z, 1)
end

do
	-- Positions from before maps existed: compass-connected groups become one map each, a
	-- group touching a mapped room joins it, and named exits do not join anything.
	local _, maps, adopted = Placement.place(graph({
		[1] = { 0, 0, 0 },
		[2] = { 1, 0, 0 },
		[5] = { 5, 0, 0 },
		[6] = { 5, 1, 0 },
		[8] = { 9, 0, 0, 3 },
		[9] = { 10, 0, 0 },
	}, {
		{ from = 1, direction = "east", to = 2 },
		{ from = 2, direction = "enter", to = 5 },
		{ from = 5, direction = "south", to = 6 },
		{ from = 8, direction = "east", to = 9 },
	}), nil)
	local map_of = {}
	for _, adoption in ipairs(adopted) do
		map_of[adoption.id] = adoption.map
	end

	expect("two new maps for two unmapped groups", #maps, 2)
	expect("street keeps one map", map_of[1] ~= nil and map_of[1] == map_of[2], true)
	expect("building behind enter is separate", map_of[5] ~= nil and map_of[5] ~= map_of[1] and map_of[5] == map_of[6], true)
	expect("lowest id is the entrance", maps[1] and maps[1].entrance, 1)
	expect("group touching a mapped room joins it", map_of[9], 3)
	expect("mapped rooms are not adopted again", map_of[8], nil)
end

do
	-- A door mark blocks layout: 2 is north of 1 but behind a door, so standing in 2 starts
	-- a new map, entered from map 5.
	local placements, maps = Placement.place(graph({ [1] = { 0, 0, 0, 5 }, [2] = true }, {
		{ from = 1, direction = "north", to = 2, boundary = "door" },
	}), 2)
	local placed = by_id(placements)

	expect("door starts a new map", placed[2] and placed[2].map, maps[1] and maps[1].key)
	expect("new map remembers its parent", maps[1] and maps[1].parent, 5)
end

do
	-- A loop 1-2-3-4: splitting 2 off from 1 is impossible, 1 is still reachable via 3 and 4.
	local loop = graph({ [1] = true, [2] = true, [3] = true, [4] = true }, {
		{ from = 1, direction = "east", to = 2 },
		{ from = 2, direction = "south", to = 3 },
		{ from = 3, direction = "west", to = 4 },
		{ from = 4, direction = "north", to = 1 },
	})

	expect("no split where the outside is reachable", Placement.inside(loop, 2, 1), nil)
	loop.exits[4].boundary = "door"
	loop.rooms[1].map_id, loop.rooms[2].map_id, loop.rooms[3].map_id, loop.rooms[4].map_id = 1, 1, 1, 9
	expect("split stays inside its map", Placement.inside(loop, 2, 1) and table.concat(Placement.inside(loop, 2, 1), ","), "2,3")
	loop.rooms[4].map_id = 1
	expect("a door elsewhere closes the loop", Placement.inside(loop, 2, 1) and table.concat(Placement.inside(loop, 2, 1), ","), "2,3,4")
end

do
	expect("map name takes the area prefix", Placement.map_name({ id = 1, name = "Newbie Tower: Forest" }), "Newbie Tower")
	expect("plain map name", Placement.map_name({ id = 1, name = "Hollow" }), "Hollow")
end

do
	local positions = { [1] = { x = 0, y = 0, z = 0, map = 1 }, [2] = { x = 1, y = 0, z = 0, map = 2 } }

	expect("compass exit across maps is irregular", Placement.geometry({ from = 1, direction = "east", to = 2 }, positions), "irregular")
end

do
	local positions = { [1] = { x = 0, y = 0, z = 0 }, [2] = { x = 1, y = 0, z = 0 }, [3] = { x = 0, y = 2, z = 0 } }

	expect("matching offset is regular", Placement.geometry({ from = 1, direction = "east", to = 2 }, positions), "regular")
	expect("contradicting offset is irregular", Placement.geometry({ from = 1, direction = "south", to = 3 }, positions), "irregular")
	expect("named exit", Placement.geometry({ from = 1, direction = "enter", to = 2 }, positions), "named")
	expect("unexplored exit", Placement.geometry({ from = 1, direction = "west" }, positions), "unknown")
	expect("unplaced endpoint", Placement.geometry({ from = 1, direction = "east", to = 9 }, positions), "unplaced")
end

-- Snapshot --------------------------------------------------------------------------------

local db_path = os.tmpname()
local map_path = os.tmpname()
os.remove(db_path)
os.remove(map_path)

do
	local memory = Memory.new(db_path)
	memory:initialize()
	expect("schema reaches latest", memory:schema_version(), Memory.SCHEMA_VERSION)

	local forest = memory:remember_room({ name = "Forest", exits = { "north", "northwest" }, fingerprint = "Forest|north,northwest", description = "Trees." })
	local path = memory:remember_room({ name = "Path", exits = { "south" }, fingerprint = "Path|south", description = "" })
	local hollow = memory:remember_room({ name = "Hollow", exits = { "out" }, fingerprint = "Hollow|out", description = "" })
	memory:connect_rooms(forest, "north", path)
	memory:connect_rooms(path, "south", forest)
	memory:connect_rooms(forest, "enter", hollow)
	memory:add_note(forest, 'Thieves "here"')

	local tracker = { current_room = forest }
	local publisher = Publisher.new(memory, tracker, map_path)

	expect("publish succeeds", publisher:publish(), true)

	local file = assert(io.open(map_path, "r"))
	local text = file:read("*a")
	file:close()

	expect("snapshot has schemaVersion 1", text:find('"schemaVersion":1', 1, true) ~= nil, true)
	expect("current room is published", text:find('"currentRoomId":' .. forest, 1, true) ~= nil, true)
	expect("unexplored exit has null destination", text:find('"direction":"northwest","from":' .. forest .. ',"geometry":"unknown","to":null', 1, true) ~= nil, true)
	expect("named exit is named", text:find('"direction":"enter","from":' .. forest .. ',"geometry":"named"', 1, true) ~= nil, true)
	expect("note text is escaped", text:find('Thieves \\"here\\"', 1, true) ~= nil, true)
	expect("unvisited component is unplaced", text:find('"positionStatus":"unplaced"', 1, true) ~= nil, true)
	expect("no temp file left behind", io.open(map_path .. ".tmp", "r"), nil)

	local first_revision = publisher.revision
	local stored = memory:get_map().rooms[path]

	-- Positions persist and survive a second publish unchanged.
	publisher:publish()
	expect("revision increases", publisher.revision > first_revision, true)
	expect("position was stored", stored.y, -1)
	expect("position does not move", memory:get_map().rooms[path].y, -1)

	-- A new publisher continues the counter from the file.
	local restarted = Publisher.new(memory, tracker, map_path)
	expect("restart continues revision", restarted.revision, publisher.revision)

	-- Unknown location publishes null instead of a stale room.
	tracker.current_room = nil
	publisher:publish()
	file = assert(io.open(map_path, "r"))
	text = file:read("*a")
	file:close()
	expect("lost position is null", text:find('"currentRoomId":null', 1, true) ~= nil, true)

	tracker.current_room = forest
	publisher:publish()

	local street_map = memory:get_map().rooms[forest].map_id
	expect("placed rooms get a map", street_map ~= nil, true)
	expect("compass neighbour shares it", memory:get_map().rooms[path].map_id, street_map)
	expect("map is named after its entrance", memory:get_map().maps[street_map].name, "Forest")

	-- Standing in the hollow lays it out as its own map.
	tracker.current_room = hollow
	publisher:publish()
	local graph_now = memory:get_map()
	local hollow_map = graph_now.rooms[hollow].map_id
	expect("room behind enter gets its own map", hollow_map ~= nil and hollow_map ~= street_map, true)
	expect("its entrance is the hollow", graph_now.maps[hollow_map].entrance_id, hollow)

	file = assert(io.open(map_path, "r"))
	text = file:read("*a")
	file:close()
	expect("room mapId is published", text:find('"mapId":' .. hollow_map, 1, true) ~= nil, true)
	expect("maps are published", text:find('{"entranceRoomId":' .. hollow .. ',"id":' .. hollow_map .. ',"name":"Hollow","realm":null,"type":"outdoor"}', 1, true) ~= nil, true)

	-- Relayout forgets coordinates but keeps maps and what the player said about them.
	memory:update_map(hollow_map, { type = "cave", realm = "Foundation" })
	memory:clear_positions()
	graph_now = memory:get_map()
	expect("relayout clears positions", graph_now.rooms[forest].x, nil)
	expect("relayout keeps maps", graph_now.maps[hollow_map] and graph_now.maps[hollow_map].type, "cave")
	expect("relayout keeps map ids", graph_now.rooms[hollow].map_id, hollow_map)
	publisher:publish()
	expect("relaid hollow keeps its map", memory:get_map().rooms[hollow].map_id, hollow_map)
	expect("relaid hollow is placed again", memory:get_map().rooms[hollow].x ~= nil, true)

	-- A shop entered by `north` from the street: split it off at that exit.
	local street = memory:remember_room({ name = "Lane", exits = { "north", "south" }, fingerprint = "Lane|north,south", description = "A lane." })
	local shop = memory:remember_room({ name = "Shop", exits = { "south", "up" }, fingerprint = "Shop|south,up", description = "Wares." })
	local attic = memory:remember_room({ name = "Attic", exits = { "down" }, fingerprint = "Attic|down", description = "Dust." })
	memory:connect_rooms(path, "north", street)
	memory:connect_rooms(street, "south", path)
	memory:connect_rooms(street, "north", shop)
	memory:connect_rooms(shop, "south", street)
	memory:connect_rooms(shop, "up", attic)
	memory:update_map(street_map, { realm = "Foundation" })
	tracker.current_room = attic
	publisher:publish()
	graph_now = memory:get_map()
	expect("shop starts in the street map", graph_now.rooms[shop].map_id, street_map)

	local inside = Placement.inside(graph_now, shop, street)
	expect("inside is shop and attic", inside and table.concat(inside, ","), shop .. "," .. attic)

	local shop_map = memory:split_map(shop, street, inside, { boundary = "door", type = "building", name = "Ye Shoppe" })
	tracker.current_room = shop
	publisher:publish()
	graph_now = memory:get_map()
	expect("shop has its own map", graph_now.rooms[shop].map_id, shop_map)
	expect("attic moved with it", graph_now.rooms[attic].map_id, shop_map)
	expect("split map keeps its name", graph_now.maps[shop_map].name, "Ye Shoppe")
	expect("split map inherits the realm", graph_now.maps[shop_map].realm, "Foundation")
	expect("split map is laid out again", graph_now.rooms[shop].x ~= nil, true)
	expect("street stays put", graph_now.rooms[street].map_id, street_map)

	file = assert(io.open(map_path, "r"))
	text = file:read("*a")
	file:close()
	expect("door is published", text:find('"boundary":"door","direction":"north","from":' .. street, 1, true) ~= nil, true)

	-- Merge it back: the shop returns north of the lane.
	memory:merge_map(shop_map)
	publisher:publish()
	graph_now = memory:get_map()
	expect("merged shop rejoins the street", graph_now.rooms[shop].map_id, street_map)
	expect("merged shop sits north of the lane", graph_now.rooms[shop].y, graph_now.rooms[street].y - 1)
	expect("merged map is gone", graph_now.maps[shop_map], nil)

	if arg[1] then
		os.execute("cp '" .. map_path .. "' '" .. arg[1] .. "'")
	end

	memory:close()
end

os.remove(db_path)
os.remove(map_path)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end

print("all publisher tests passed")
