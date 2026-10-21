-- publisher/init.lua
-- Writes the read-only map snapshot that QREEP watches (schema version 1).
--
-- Contract (matches QREEP's modules/qreeper/README.md):
--   path      $QREEP_QREEPER_MAP_PATH, else ~/.local/state/qreeper/map.json
--   write     temp file in the same directory, then os.rename over map.json (atomic)
--   revision  strictly increasing: max(last + 1, os.time()), continued from the existing file
--   when      after every finished room observation, note/geography change, plugin load,
--             and every HEARTBEAT_SECONDS so QREEP can tell "standing still" from "stopped"
--
-- The snapshot is derived from SQLite plus the tracker; it is never read back as truth.
-- Publishing failures are reported once in scrollback and never break room tracking.

local Json = require("publisher.json")
local Placement = require("publisher.placement")

local Publisher = {}
Publisher.__index = Publisher

-- Rewrite interval while connected. QREEP marks a snapshot stale after 5 minutes of no new
-- revision, so this keeps an idle-but-running Qreeper looking alive.
Publisher.HEARTBEAT_SECONDS = 60

local WORLD = "3scapes"

---Default snapshot path, overridable for testing with the same variable QREEP reads.
---@return string
function Publisher.default_path()
	local override = os.getenv("QREEP_QREEPER_MAP_PATH")

	if override and override ~= "" then
		return override
	end

	return assert(os.getenv("HOME")) .. "/.local/state/qreeper/map.json"
end

---Last revision found in an existing snapshot file, or 0. Read with a Lua pattern; there is
---no need to decode the whole file to continue a counter.
---@param path string
---@return integer
local function read_revision(path)
	local file = io.open(path, "r")

	if not file then
		return 0
	end

	local text = file:read("*a") or ""
	file:close()

	return tonumber(text:match('"revision"%s*:%s*(%d+)')) or 0
end

---Create the snapshot directory. Blightmud has no mkdir API, so this shells out once.
---@param path string Snapshot file path.
local function ensure_directory(path)
	local directory = path:match("^(.*)/[^/]*$")

	if directory and directory ~= "" then
		os.execute("mkdir -p '" .. directory:gsub("'", "'\\''") .. "'")
	end
end

---SQLite CURRENT_TIMESTAMP ("YYYY-MM-DD HH:MM:SS", UTC) to ISO 8601.
---@param value string|nil
---@return string|table
local function iso_time(value)
	if not value or value == "" then
		return Json.null
	end

	return (value:gsub(" ", "T")) .. "Z"
end

---Lua nil to JSON null for optional snapshot fields.
local function nullable(value)
	if value == nil then
		return Json.null
	end

	return value
end

---Create a publisher.
---@param memory table
---@param tracker table
---@param path string|nil Snapshot path; defaults to Publisher.default_path().
function Publisher.new(memory, tracker, path)
	path = path or Publisher.default_path()

	return setmetatable({
		memory = memory,
		tracker = tracker,
		path = path,
		revision = read_revision(path),
		last_error = nil,
	}, Publisher)
end

---Next revision: always above the previous one and, after a restart, above anything the
---running QREEP has seen (epoch seconds are the floor).
---@return integer
function Publisher:next_revision()
	self.revision = math.max(self.revision + 1, os.time())
	return self.revision
end

---Build the snapshot table. Also stores positions for rooms placed for the first time.
---@return table
function Publisher:build()
	local graph = self.memory:get_map()
	local current_id = self.tracker.current_room

	local placements, new_maps, adopted = Placement.place(graph, current_id)

	if #placements > 0 or #adopted > 0 then
		local map_ids = self.memory:set_positions(placements, new_maps, adopted)

		for _, placement in ipairs(placements) do
			local room = graph.rooms[placement.id]
			room.x, room.y, room.z = placement.x, placement.y, placement.z
			room.position_status = "inferred"
			room.map_id = map_ids[placement.map] or placement.map
		end

		for _, adoption in ipairs(adopted) do
			graph.rooms[adoption.id].map_id = map_ids[adoption.map] or adoption.map
		end

		if #new_maps > 0 then
			graph.maps = self.memory:get_maps()
		end
	end

	local notes_by_room = self.memory:get_all_notes()
	local positions = {}
	local ids = {}

	for id, room in pairs(graph.rooms) do
		table.insert(ids, id)

		if room.x ~= nil and room.y ~= nil and room.z ~= nil then
			positions[id] = { x = room.x, y = room.y, z = room.z, map = room.map_id }
		end
	end

	table.sort(ids)

	local rooms = Json.array()

	for _, id in ipairs(ids) do
		local room = graph.rooms[id]
		local placed = positions[id] ~= nil
		local notes = Json.array()

		for _, note in ipairs(notes_by_room[id] or {}) do
			table.insert(notes, {
				id = note.id,
				text = note.content,
				createdAt = iso_time(note.created_at),
			})
		end

		table.insert(rooms, {
			id = id,
			name = room.name,
			description = nullable(room.description ~= "" and room.description or nil),
			level = nullable(room.level),
			x = placed and room.x or Json.null,
			y = placed and room.y or Json.null,
			z = placed and room.z or Json.null,
			mapId = nullable(placed and room.map_id or nil),
			positionStatus = placed and (room.position_status or "inferred") or "unplaced",
			marked = room.marked == true,
			notes = notes,
		})
	end

	local exits = Json.array()

	for _, exit in ipairs(graph.exits) do
		table.insert(exits, {
			from = exit.from,
			direction = exit.direction,
			to = nullable(exit.to),
			guessed = exit.guessed == true,
			boundary = nullable(exit.boundary),
			geometry = Placement.geometry(exit, positions),
		})
	end

	-- Maps that still hold a placed room; an emptied one (forgotten rooms) is not published.
	local maps = Json.array()
	local used = {}

	for _, room in pairs(graph.rooms) do
		if room.map_id and positions[room.id] then
			used[room.map_id] = true
		end
	end

	local map_ids = {}

	for id in pairs(graph.maps) do
		if used[id] then
			table.insert(map_ids, id)
		end
	end

	table.sort(map_ids)

	for _, id in ipairs(map_ids) do
		local map = graph.maps[id]
		local entrance = map.entrance_id and graph.rooms[map.entrance_id] and map.entrance_id or nil

		table.insert(maps, {
			id = id,
			name = map.name,
			type = map.type,
			realm = nullable(map.realm),
			entranceRoomId = nullable(entrance),
		})
	end

	return {
		schemaVersion = 1,
		world = WORLD,
		revision = self:next_revision(),
		publishedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		currentRoomId = nullable(graph.rooms[current_id or -1] and current_id or nil),
		rooms = rooms,
		exits = exits,
		maps = maps,
		layout = {
			coordinateSystem = "east+x,south+y,up+z",
		},
	}
end

---Write text to the snapshot path atomically: temp file in the same directory, then rename.
---@param text string
function Publisher:write(text)
	local temporary = self.path .. ".tmp"
	local file = io.open(temporary, "w")

	if not file then
		ensure_directory(self.path)
		file = assert(io.open(temporary, "w"))
	end

	assert(file:write(text, "\n"))
	assert(file:close())
	assert(os.rename(temporary, self.path))
end

---Build and write a snapshot. Never raises: tracking matters more than the minimap.
---@return boolean ok
function Publisher:publish()
	local ok, err = pcall(function()
		self:write(Json.encode(self:build()))
	end)

	if ok then
		self.last_error = nil
		return true
	end

	-- Report each distinct failure once, not on every room.
	local message = tostring(err)

	if message ~= self.last_error then
		self.last_error = message
		blight.output("Qreeper map snapshot failed: " .. message)
	end

	return false
end

return Publisher
