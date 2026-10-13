-- memory.lua
-- Qreeper's durable world record: rooms, directed exits and notes in SQLite.
--
-- This module is the only code that talks SQL. Callers get plain Lua tables back and
-- never see statements. Every query uses prepared statements with bound values.
--
-- Schema changes go through MIGRATIONS below and are tracked with `PRAGMA user_version`.
-- Never edit a migration that has shipped; append a new one instead.

local sqlite3 = require("lsqlite3")
local Identity = require("identity")
local Placement = require("publisher.placement")

local Memory = {}
Memory.__index = Memory

-- Ordered schema migrations. Index N moves the database from version N-1 to version N.
-- Version 1 is the original schema. It uses IF NOT EXISTS so databases created before
-- versioning existed (user_version 0, tables already present) are adopted unchanged.
local MIGRATIONS = {
	[1] = [[
        CREATE TABLE IF NOT EXISTS rooms (
            id INTEGER PRIMARY KEY,
            fingerprint TEXT,
            name TEXT NOT NULL,
            description TEXT,

            realm TEXT,
            area TEXT,
            level INTEGER,
            x INTEGER,
            y INTEGER,

            first_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_rooms_area
            ON rooms(realm, area, level);

        CREATE INDEX IF NOT EXISTS idx_rooms_fingerprint
            ON rooms(fingerprint);

        CREATE TABLE IF NOT EXISTS exits (
            id INTEGER PRIMARY KEY,
            room_id INTEGER NOT NULL,
            direction TEXT NOT NULL,
            destination_id INTEGER,

            FOREIGN KEY (room_id)
                REFERENCES rooms(id) ON DELETE CASCADE,

            FOREIGN KEY (destination_id)
                REFERENCES rooms(id) ON DELETE SET NULL,

            UNIQUE (room_id, direction)
        );

        CREATE TABLE IF NOT EXISTS notes (
            id INTEGER PRIMARY KEY,
            room_id INTEGER NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

            FOREIGN KEY (room_id)
                REFERENCES rooms(id) ON DELETE CASCADE
        );
    ]],

	-- Stored map positions for the QREEP snapshot. x/y already existed (always NULL so far);
	-- z is the relative layout height, not the in-game `level`. position_status is NULL until
	-- the publisher places the room, then "inferred". Positions are written once, never moved.
	[2] = [[
        ALTER TABLE rooms ADD COLUMN z INTEGER;
        ALTER TABLE rooms ADD COLUMN position_status TEXT;
    ]],

	-- Lines seen after "Obvious exits" on every visit so far (statues, fixed items), one per
	-- line. Identity evidence for rooms that are otherwise identical; see identity.lua.
	[3] = [[
        ALTER TABLE rooms ADD COLUMN details TEXT;
    ]],

	-- Maps: separately laid-out groups of rooms (the streets, a building, a dungeon), joined
	-- by named exits. x/y/z are only comparable inside one map. Derived layout data like the
	-- positions: the publisher assigns map_id when it places a room. `name` defaults to the
	-- entrance room's name. Not to be confused with `area`, the label set by hand.
	[4] = [[
        CREATE TABLE maps (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            entrance_room_id INTEGER,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

            FOREIGN KEY (entrance_room_id)
                REFERENCES rooms(id) ON DELETE SET NULL
        );

        ALTER TABLE rooms ADD COLUMN map_id INTEGER REFERENCES maps(id) ON DELETE SET NULL;

        CREATE INDEX idx_rooms_map ON rooms(map_id);
    ]],

	-- Map kinds and realms replace the per-room `realm`/`area` labels (never filled in this
	-- database). map_types is a list the player extends (`qreeper:map-type-add Sewer`); names
	-- are stored lowercase and checked in Lua, because SQLite cannot add a REFERENCES column
	-- with a non-NULL default. exits.boundary marks the exit between two maps that is not a
	-- named exit: 'door' (a compass step into a building) or 'portal' (into another realm).
	-- Placement never lays rooms out across a boundary.
	[5] = [[
        CREATE TABLE map_types (
            name TEXT PRIMARY KEY
        );

        INSERT INTO map_types (name) VALUES ('outdoor'), ('building'), ('cave');

        ALTER TABLE maps ADD COLUMN type TEXT NOT NULL DEFAULT 'outdoor';
        ALTER TABLE maps ADD COLUMN realm TEXT;
        ALTER TABLE exits ADD COLUMN boundary TEXT;

        DROP INDEX IF EXISTS idx_rooms_area;
        ALTER TABLE rooms DROP COLUMN area;
        ALTER TABLE rooms DROP COLUMN realm;
    ]],
}

-- Latest schema version this plugin writes.
Memory.SCHEMA_VERSION = #MIGRATIONS

---Split stored details text into lines.
---@param text string|nil
---@return string[]
local function split_details(text)
	local lines = {}

	for line in tostring(text or ""):gmatch("[^\n]+") do
		table.insert(lines, line)
	end

	return lines
end

---Join detail lines for storage; nil when there are none.
---@param lines string[]|nil
---@return string|nil
local function join_details(lines)
	if not lines or #lines == 0 then
		return nil
	end

	return table.concat(lines, "\n")
end

---Open (or create) the world database. Call `initialize()` before using it.
---@param path string
function Memory.new(path)
	local db = sqlite3.open(path)

	assert(db, "Qreeper memory could not be opened")

	local self = setmetatable({
		db = db,
	}, Memory)

	assert(db:exec("PRAGMA foreign_keys = ON") == sqlite3.OK, db:errmsg())

	return self
end

---Run `callback` inside one transaction; roll back and re-raise if it fails.
---Not re-entrant: do not call it from inside another transaction.
---@param callback function
---@return any, any, any # The callback's first three return values.
function Memory:transaction(callback)
	assert(self.db:exec("BEGIN IMMEDIATE") == sqlite3.OK, self.db:errmsg())

	local ok, first, second, third = pcall(callback)

	if not ok then
		self.db:exec("ROLLBACK")
		error(first, 0)
	end

	assert(self.db:exec("COMMIT") == sqlite3.OK, self.db:errmsg())

	return first, second, third
end

---Current schema version stored in the database file.
---@return integer
function Memory:schema_version()
	local version = 0

	for row in self.db:nrows("PRAGMA user_version") do
		version = row.user_version
	end

	return version
end

---Bring the schema up to date. Each migration runs in its own transaction, so a failure
---leaves the database at the last fully applied version.
function Memory:initialize()
	local version = self:schema_version()

	assert(
		version <= #MIGRATIONS,
		"Qreeper database schema v" .. version .. " is newer than this plugin (v" .. #MIGRATIONS .. ")"
	)

	for target = version + 1, #MIGRATIONS do
		self:transaction(function()
			assert(self.db:exec(MIGRATIONS[target]) == sqlite3.OK, self.db:errmsg())
			-- PRAGMA cannot take a bound parameter; `target` is a loop integer, not input.
			assert(self.db:exec("PRAGMA user_version = " .. target) == sqlite3.OK, self.db:errmsg())
		end)
	end
end

---Record a directed exit `from --direction--> to`.
---Fills an unknown destination, confirms an identical one, and refuses to overwrite a
---different known destination.
---@return boolean connected False when the stored exit disagrees with this observation.
function Memory:connect_rooms(from_id, direction, to_id)
	if not from_id or not to_id or not direction then
		return false
	end

	local stmt = assert(self.db:prepare([[
        INSERT INTO exits (room_id, direction, destination_id)
        VALUES (?, ?, ?)

        ON CONFLICT(room_id, direction)
        DO UPDATE SET destination_id = excluded.destination_id
        WHERE exits.destination_id IS NULL
           OR exits.destination_id = excluded.destination_id
    ]]))

	assert(stmt:bind_values(from_id, direction, to_id) == sqlite3.OK)

	local result = stmt:step()
	stmt:finalize()

	assert(result == sqlite3.DONE, self.db:errmsg())

	return self.db:changes() > 0
end

---Match an observed room to a stored one, or create it. Identity rules live in identity.lua:
---fingerprint narrows the candidates, then graph evidence and description similarity decide.
---Also records every advertised exit (destination unknown until travelled).
---@param room table Observer snapshot: `{ name, exits, fingerprint, description, details }`;
---`details` is nil while the lines after the summary have not arrived.
---@param evidence table|nil `{ predicted_id, from_id, direction }`, see Identity.choose; the
---direction of the move marks lookalikes far from where it should land.
---@return integer|nil id
---@return string status `"new"`, `"twin"` (new room sharing a name and exits with a stored
---one), `"known"`, `"ambiguous"` or `"need-details"` (id is nil for the last two; nothing
---is written for them).
function Memory:remember_room(room, evidence)
	evidence = evidence or {}
	local db = self.db

	return self:transaction(function()
		local query = assert(db:prepare([[
            SELECT id, description, details, x, y, z, map_id
            FROM rooms
            WHERE fingerprint = ?
            ORDER BY id
        ]]))

		assert(query:bind_values(room.fingerprint) == sqlite3.OK)

		-- Where a compass move from `from_id` should land, if the start is placed.
		local expected = self:expected_cell(evidence.from_id, evidence.direction)

		local candidates = {}
		for row in query:nrows() do
			local far = false

			if expected and row.x and row.y and row.map_id == expected.map then
				far = math.max(
					math.abs(row.x - expected.x),
					math.abs(row.y - expected.y),
					math.abs((row.z or 0) - expected.z)
				) > 1
			end

			table.insert(candidates, {
				id = row.id,
				description = row.description,
				details = split_details(row.details),
				far = far,
			})
		end
		query:finalize()

		local crowd = assert(db:prepare([[
            SELECT COUNT(*) AS count FROM rooms WHERE name = ?
        ]]))

		assert(crowd:bind_values(room.name) == sqlite3.OK)

		local same_name = 0
		for row in crowd:nrows() do
			same_name = row.count
		end
		crowd:finalize()

		local id, status = Identity.choose(candidates, {
			description = room.description,
			details = room.details,
			predicted_id = evidence.predicted_id,
			from_id = evidence.from_id,
			crowded = same_name >= 2,
		})

		if status == "ambiguous" or status == "need-details" then
			return nil, status
		end

		local created = false

		if id then
			-- Known room: refresh the visit time and keep the latest non-empty description.
			local stmt = assert(db:prepare([[
                UPDATE rooms
                SET
                    last_seen_at = CURRENT_TIMESTAMP,
                    description = CASE
                        WHEN ? IS NOT NULL AND ? <> ''
                        THEN ?
                        ELSE description
                    END
                WHERE id = ?
            ]]))

			assert(stmt:bind_values(room.description, room.description, room.description, id) == sqlite3.OK)
			local result = stmt:step()
			stmt:finalize()
			assert(result == sqlite3.DONE, db:errmsg())

			if room.details then
				self:merge_details(id, room.details)
			end
		else
			id = self:add_room(room)
			created = true
		end

		local exit_stmt = assert(db:prepare([[
            INSERT OR IGNORE INTO exits (room_id, direction)
            VALUES (?, ?)
        ]]))

		for _, direction in ipairs(room.exits) do
			assert(exit_stmt:bind_values(id, direction) == sqlite3.OK)
			local result = exit_stmt:step()
			assert(result == sqlite3.DONE, db:errmsg())
			exit_stmt:reset()
		end

		exit_stmt:finalize()

		-- `status` is "new" or "twin" when created; anything matched is "known".
		return id, created and status or "known"
	end)
end

---The cell a compass or up/down move from a placed room should land in, or nil.
---@param from_id integer|nil
---@param direction string|nil
---@return table|nil cell `{ x, y, z, map }`
function Memory:expected_cell(from_id, direction)
	local offset = direction and Placement.OFFSETS[direction]

	if not from_id or not offset then
		return nil
	end

	local stmt = assert(self.db:prepare([[
        SELECT x, y, z, map_id FROM rooms WHERE id = ?
    ]]))

	assert(stmt:bind_values(from_id) == sqlite3.OK)

	local cell

	for row in stmt:nrows() do
		if row.x and row.y then
			cell = {
				x = row.x + offset[1],
				y = row.y + offset[2],
				z = (row.z or 0) + offset[3],
				map = row.map_id,
			}
		end
	end

	stmt:finalize()

	return cell
end

---Fold a visit's detail lines into a room's stored details (keep what survives visits).
---@param id integer
---@param observed string[]
function Memory:merge_details(id, observed)
	local stored

	for value in self.db:urows("SELECT COALESCE(details, '') FROM rooms WHERE id = " .. math.tointeger(id)) do
		stored = value
	end

	if stored == nil then
		return
	end

	local merged = join_details(Identity.stable_details(split_details(stored), observed))
	local stmt = assert(self.db:prepare("UPDATE rooms SET details = ? WHERE id = ?"))
	assert(stmt:bind_values(merged, id) == sqlite3.OK)
	local result = stmt:step()
	stmt:finalize()
	assert(result == sqlite3.DONE, self.db:errmsg())
end

---Details that arrived after the room was already stored (the normal case: the room is
---recorded at "Obvious exits", its statues follow a moment later).
---@param id integer
---@param observed string[]
function Memory:update_details(id, observed)
	self:transaction(function()
		self:merge_details(id, observed)
	end)
end

---Insert a newly discovered room.
---@param room table
---@return integer
function Memory:add_room(room)
	local stmt = assert(self.db:prepare([[
        INSERT INTO rooms (
            fingerprint,
            name,
            description,
            level,
            x,
            y,
            details
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]]))

	local bound = stmt:bind_values(
		room.fingerprint,
		room.name,
		room.description,
		room.level,
		room.x,
		room.y,
		join_details(room.details)
	)

	assert(bound == sqlite3.OK, self.db:errmsg())

	local result = stmt:step()
	stmt:finalize()

	assert(result == sqlite3.DONE, self.db:errmsg())

	return self.db:last_insert_rowid()
end

---Get a room's level, or nil if the room does not exist. Realm and map live on the room's
---map; see get_room_map.
---@param id integer
---@return table|nil `{ level }`
function Memory:get_room_location(id)
	local stmt = assert(self.db:prepare([[
        SELECT level
        FROM rooms
        WHERE id = ?
    ]]))

	assert(stmt:bind_values(id) == sqlite3.OK)

	local location

	for row in stmt:nrows() do
		location = {
			level = row.level,
		}
	end

	stmt:finalize()

	return location
end

---Set a room's level. `field` stays a parameter for callers; only "level" is left.
---@param id integer
---@param field "level"
---@param value integer
function Memory:set_room_location(id, field, value)
	assert(field == "level", "Invalid location field")

	local stmt = assert(self.db:prepare("UPDATE rooms SET level = ? WHERE id = ?"))

	assert(stmt:bind_values(value, id) == sqlite3.OK)

	local result = stmt:step()
	stmt:finalize()

	assert(result == sqlite3.DONE, self.db:errmsg())
end

---Attach a note to a room.
---@param room_id integer
---@param content string
---@return integer note_id
function Memory:add_note(room_id, content)
	local stmt = assert(self.db:prepare([[
        INSERT INTO notes (room_id, content)
        VALUES (?, ?)
    ]]))

	assert(stmt:bind_values(room_id, content) == sqlite3.OK)

	local result = stmt:step()
	stmt:finalize()

	assert(result == sqlite3.DONE, self.db:errmsg())

	return self.db:last_insert_rowid()
end

---Retrieve notes belonging to a room, oldest first.
---@param room_id integer
---@return table[]
function Memory:get_notes(room_id)
	local stmt = assert(self.db:prepare([[
        SELECT id, content, created_at
        FROM notes
        WHERE room_id = ?
        ORDER BY id ASC
    ]]))

	assert(stmt:bind_values(room_id) == sqlite3.OK)

	local notes = {}

	for row in stmt:nrows() do
		table.insert(notes, {
			id = row.id,
			content = row.content,
			created_at = row.created_at,
		})
	end

	stmt:finalize()
	return notes
end

---Delete a note, but only if it belongs to the given room.
---@param room_id integer
---@param note_id integer
---@return boolean deleted
function Memory:delete_note(room_id, note_id)
	local stmt = assert(self.db:prepare([[
        DELETE FROM notes
        WHERE id = ? AND room_id = ?
    ]]))

	assert(stmt:bind_values(note_id, room_id) == sqlite3.OK)

	local result = stmt:step()
	stmt:finalize()

	assert(result == sqlite3.DONE, self.db:errmsg())

	return self.db:changes() > 0
end

---Rooms that have at least one note, with their note counts and map.
---@return table[]
function Memory:get_rooms_with_notes()
	local stmt = assert(self.db:prepare([[
        SELECT
            r.id,
            r.name,
            m.realm,
            m.name AS map_name,
            r.level,
            COUNT(n.id) AS note_count
        FROM rooms r
        INNER JOIN notes n ON n.room_id = r.id
        LEFT JOIN maps m ON m.id = r.map_id
        GROUP BY r.id
        ORDER BY
            m.realm,
            m.name,
            r.name,
            r.id
    ]]))

	local rooms = {}

	for row in stmt:nrows() do
		table.insert(rooms, {
			id = row.id,
			name = row.name,
			realm = row.realm,
			map_name = row.map_name,
			level = row.level,
			note_count = row.note_count,
		})
	end

	stmt:finalize()

	return rooms
end

---Every map: `{ [id] = { id, name, entrance_id, type, realm } }`.
---@return table<integer, table>
function Memory:get_maps()
	local maps = {}

	for row in self.db:nrows("SELECT id, name, entrance_room_id, type, realm FROM maps ORDER BY id") do
		maps[row.id] = { id = row.id, name = row.name, entrance_id = row.entrance_room_id, type = row.type, realm = row.realm }
	end

	return maps
end

---The whole room graph: rooms keyed by id, exits as a directed list (`to` may be nil).
---Rooms carry stored positions (`x`, `y`, `z`, `position_status`, `map_id`), all nil until
---placed.
---@return table `{ rooms = { [id] = room }, exits = { { from, direction, to } },
---maps = { [id] = { id, name, entrance_id } } }`
function Memory:get_map()
	local rooms = {}
	local exits = {}
	local maps = self:get_maps()

	local room_query = assert(self.db:prepare([[
        SELECT id, name, description, level, x, y, z, position_status, map_id
        FROM rooms
        ORDER BY id
    ]]))

	for row in room_query:nrows() do
		rooms[row.id] = {
			id = row.id,
			name = row.name,
			description = row.description,
			level = row.level,
			x = row.x,
			y = row.y,
			z = row.z,
			position_status = row.position_status,
			map_id = row.map_id,
		}
	end

	room_query:finalize()

	local exit_query = assert(self.db:prepare([[
        SELECT room_id, direction, destination_id, boundary
        FROM exits
        ORDER BY room_id, direction
    ]]))

	for row in exit_query:nrows() do
		table.insert(exits, {
			from = row.room_id,
			direction = row.direction,
			to = row.destination_id,
			boundary = row.boundary,
		})
	end

	exit_query:finalize()

	return {
		rooms = rooms,
		exits = exits,
		maps = maps,
	}
end

---The most recent note text for each room that has notes.
---@return table<integer, string>
function Memory:get_latest_notes()
	local stmt = assert(self.db:prepare([[
        SELECT n.room_id, n.content
        FROM notes n
        WHERE n.id = (
            SELECT MAX(n2.id)
            FROM notes n2
            WHERE n2.room_id = n.room_id
        )
    ]]))

	local notes = {}

	for row in stmt:nrows() do
		notes[row.room_id] = row.content
	end

	stmt:finalize()

	return notes
end

---Exits of one room as `{ [direction] = destination_id | false }`; false means unexplored.
---@param room_id integer
---@return table<string, integer|false>
function Memory:get_room_exits(room_id)
	local stmt = assert(self.db:prepare([[
        SELECT direction, destination_id
        FROM exits
        WHERE room_id = ?
    ]]))

	assert(stmt:bind_values(room_id) == sqlite3.OK)

	local exits = {}

	for row in stmt:nrows() do
		exits[row.direction] = row.destination_id or false
	end

	stmt:finalize()

	return exits
end

---One room with its position and map, for `qreeper:where`.
---@param id integer
---@return table|nil room `{ id, name, level, x, y, z, map_id, map_name, map_type, realm,
---entrance_id, exits }`; exits are `{ direction, to, boundary, map_id, map_name }`.
function Memory:get_room(id)
	local stmt = assert(self.db:prepare([[
        SELECT r.id, r.name, r.level, r.x, r.y, r.z, r.map_id,
               m.name AS map_name, m.type AS map_type, m.realm, m.entrance_room_id
        FROM rooms r
        LEFT JOIN maps m ON m.id = r.map_id
        WHERE r.id = ?
    ]]))

	assert(stmt:bind_values(id) == sqlite3.OK)

	local room

	for row in stmt:nrows() do
		room = {
			id = row.id,
			name = row.name,
			level = row.level,
			x = row.x,
			y = row.y,
			z = row.z,
			map_id = row.map_id,
			map_name = row.map_name,
			map_type = row.map_type,
			realm = row.realm,
			entrance_id = row.entrance_room_id,
		}
	end

	stmt:finalize()

	if not room then
		return nil
	end

	stmt = assert(self.db:prepare([[
        SELECT e.direction, e.destination_id, e.boundary, d.map_id AS destination_map_id,
               m.name AS destination_map_name
        FROM exits e
        LEFT JOIN rooms d ON d.id = e.destination_id
        LEFT JOIN maps m ON m.id = d.map_id
        WHERE e.room_id = ?
        ORDER BY e.direction
    ]]))

	assert(stmt:bind_values(id) == sqlite3.OK)

	room.exits = {}

	for row in stmt:nrows() do
		table.insert(room.exits, {
			direction = row.direction,
			to = row.destination_id,
			boundary = row.boundary,
			map_id = row.destination_map_id,
			map_name = row.destination_map_name,
		})
	end

	stmt:finalize()

	return room
end

---All known rooms for the room catalogue, ordered by id, with their map's name and realm.
---@return table[]
function Memory:get_rooms()
	local stmt = assert(self.db:prepare([[
        SELECT r.id, r.name, r.level, m.name AS map_name, m.realm
        FROM rooms r
        LEFT JOIN maps m ON m.id = r.map_id
        ORDER BY r.id
    ]]))

	local rooms = {}

	for row in stmt:nrows() do
		table.insert(rooms, {
			id = row.id,
			name = row.name,
			map = row.map_name,
			realm = row.realm,
			level = row.level,
		})
	end

	stmt:finalize()

	return rooms
end

---Store a layout from publisher/placement.lua in one transaction: create the new maps, then
---first-time positions, then map ids. Rooms that already have a position or a map are left
---alone, so a later layout can never move them.
---@param placements table[] `{ id, x, y, z, map }` newly positioned rooms.
---@param maps table[]|nil New maps `{ key, entrance, name, parent }`; a new map inherits the
---realm of its parent map (the map you walked in from), if any.
---@param adopted table[]|nil `{ id, map }` positioned rooms that had no map yet.
---@return table<string, integer> map_ids New-map key -> stored map id.
function Memory:set_positions(placements, maps, adopted)
	return self:transaction(function()
		local map_ids = {}

		local function resolve(map)
			return map_ids[map] or math.tointeger(map)
		end

		local map_stmt = assert(self.db:prepare([[
            INSERT INTO maps (name, entrance_room_id, realm)
            VALUES (?, ?, (SELECT realm FROM maps WHERE id = ?))
        ]]))

		for _, map in ipairs(maps or {}) do
			local parent = map.parent ~= nil and resolve(map.parent) or nil
			assert(map_stmt:bind_values(map.name, map.entrance, parent) == sqlite3.OK)
			local result = map_stmt:step()
			assert(result == sqlite3.DONE, self.db:errmsg())
			map_ids[map.key] = self.db:last_insert_rowid()
			map_stmt:reset()
		end

		map_stmt:finalize()

		local stmt = assert(self.db:prepare([[
            UPDATE rooms
            SET x = ?, y = ?, z = ?, position_status = 'inferred'
            WHERE id = ? AND x IS NULL AND y IS NULL AND z IS NULL
        ]]))
		local room_map_stmt = assert(self.db:prepare([[
            UPDATE rooms SET map_id = ? WHERE id = ? AND map_id IS NULL
        ]]))

		local function assign_map(id, map)
			local map_id = map ~= nil and resolve(map) or nil

			if map_id then
				assert(room_map_stmt:bind_values(map_id, id) == sqlite3.OK)
				local result = room_map_stmt:step()
				assert(result == sqlite3.DONE, self.db:errmsg())
				room_map_stmt:reset()
			end
		end

		for _, placement in ipairs(placements) do
			assert(stmt:bind_values(placement.x, placement.y, placement.z, placement.id) == sqlite3.OK)
			local result = stmt:step()
			assert(result == sqlite3.DONE, self.db:errmsg())
			stmt:reset()
			assign_map(placement.id, placement.map)
		end

		for _, adoption in ipairs(adopted or {}) do
			assign_map(adoption.id, adoption.map)
		end

		stmt:finalize()
		room_map_stmt:finalize()

		return map_ids
	end)
end

---Forget every stored map position so the publisher lays rooms out again from scratch.
---Rooms keep their map, so map types, names, realms and door/portal marks (the player's
---decisions) survive; only coordinates are derived data. Rooms, exits and notes are untouched.
---@return integer cleared Number of rooms that had a position.
function Memory:clear_positions()
	local stmt = assert(self.db:prepare([[
        UPDATE rooms
        SET x = NULL, y = NULL, z = NULL, position_status = NULL
        WHERE x IS NOT NULL OR y IS NOT NULL OR z IS NOT NULL
    ]]))

	local result = stmt:step()
	stmt:finalize()

	assert(result == sqlite3.DONE, self.db:errmsg())

	return self.db:changes()
end

---Delete a misidentified room and every exit leaving it. Exits arriving from other rooms
---keep their direction but lose the destination (foreign key SET NULL), so walking them
---again relearns where they really go. Refuses rooms with notes, which are not derived data.
---@param id integer
---@return boolean deleted
---@return string|nil reason `"missing"` or `"notes"` when not deleted.
---@return integer|nil count Number of notes when the reason is `"notes"`.
function Memory:forget_room(id)
	return self:transaction(function()
		local exists = false

		for _ in self.db:urows("SELECT 1 FROM rooms WHERE id = " .. math.tointeger(id)) do
			exists = true
		end

		if not exists then
			return false, "missing"
		end

		local notes = 0

		for count in self.db:urows("SELECT COUNT(*) FROM notes WHERE room_id = " .. math.tointeger(id)) do
			notes = count
		end

		if notes > 0 then
			return false, "notes", notes
		end

		local stmt = assert(self.db:prepare("DELETE FROM rooms WHERE id = ?"))
		assert(stmt:bind_values(id) == sqlite3.OK)
		local result = stmt:step()
		stmt:finalize()
		assert(result == sqlite3.DONE, self.db:errmsg())

		return true
	end)
end

---Room pairs that record the *same* compass direction both ways (`36 east -> 37` and
---`37 east -> 36`). Real streets almost never do that; it is the signature of lookalike rooms
---merged into one by the identity rules before details/descriptions were used.
---@return table[] `{ a, b, direction, a_name, b_name }`
function Memory:find_suspicious_pairs()
	local stmt = assert(self.db:prepare([[
        SELECT a.room_id, a.destination_id, a.direction, ra.name, rb.name
        FROM exits a
        JOIN exits b ON b.room_id = a.destination_id AND b.destination_id = a.room_id
        JOIN rooms ra ON ra.id = a.room_id
        JOIN rooms rb ON rb.id = a.destination_id
        WHERE a.room_id < a.destination_id
          AND a.direction = b.direction
          AND a.direction IN ('north', 'south', 'east', 'west',
                              'northeast', 'northwest', 'southeast', 'southwest')
        ORDER BY a.room_id, a.destination_id, a.direction
    ]]))

	local pairs_found = {}

	for a, b, direction, a_name, b_name in stmt:urows() do
		table.insert(pairs_found, { a = a, b = b, direction = direction, a_name = a_name, b_name = b_name })
	end

	stmt:finalize()

	return pairs_found
end

---Every note grouped by room, oldest first: `{ [room_id] = { { id, content, created_at } } }`.
---@return table<integer, table[]>
function Memory:get_all_notes()
	local stmt = assert(self.db:prepare([[
        SELECT id, room_id, content, created_at
        FROM notes
        ORDER BY room_id, id
    ]]))

	local notes = {}

	for row in stmt:nrows() do
		notes[row.room_id] = notes[row.room_id] or {}
		table.insert(notes[row.room_id], {
			id = row.id,
			content = row.content,
			created_at = row.created_at,
		})
	end

	stmt:finalize()

	return notes
end

-- Maps ----------------------------------------------------------------------------------

---Known map types, alphabetical.
---@return string[]
function Memory:get_map_types()
	local types = {}

	for name in self.db:urows("SELECT name FROM map_types ORDER BY name") do
		table.insert(types, name)
	end

	return types
end

---Normalise a map type name, or nil when it is not a known type.
---@param name string
---@return string|nil
function Memory:find_map_type(name)
	local stmt = assert(self.db:prepare("SELECT name FROM map_types WHERE name = lower(?)"))
	assert(stmt:bind_values(name) == sqlite3.OK)

	local found

	for value in stmt:urows() do
		found = value
	end

	stmt:finalize()

	return found
end

---Add a map type (stored lowercase).
---@param name string
---@return boolean added False when it already existed.
function Memory:add_map_type(name)
	local stmt = assert(self.db:prepare("INSERT OR IGNORE INTO map_types (name) VALUES (lower(?))"))
	assert(stmt:bind_values(name) == sqlite3.OK)
	local result = stmt:step()
	stmt:finalize()
	assert(result == sqlite3.DONE, self.db:errmsg())

	return self.db:changes() > 0
end

---The map a room is in, or nil when it has none yet.
---@param room_id integer
---@return table|nil `{ id, name, entrance_id, type, realm }`
function Memory:get_room_map(room_id)
	local stmt = assert(self.db:prepare([[
        SELECT m.id, m.name, m.entrance_room_id, m.type, m.realm
        FROM rooms r
        JOIN maps m ON m.id = r.map_id
        WHERE r.id = ?
    ]]))

	assert(stmt:bind_values(room_id) == sqlite3.OK)

	local map

	for row in stmt:nrows() do
		map = { id = row.id, name = row.name, entrance_id = row.entrance_room_id, type = row.type, realm = row.realm }
	end

	stmt:finalize()

	return map
end

---Change a map's type, name and/or realm. Nil fields are left alone. `type` must already be
---normalised with find_map_type.
---@param map_id integer
---@param fields table `{ type, name, realm }`
function Memory:update_map(map_id, fields)
	local stmt = assert(self.db:prepare([[
        UPDATE maps
        SET type = COALESCE(?, type), name = COALESCE(?, name), realm = COALESCE(?, realm)
        WHERE id = ?
    ]]))

	assert(stmt:bind_values(fields.type, fields.name, fields.realm, map_id) == sqlite3.OK)
	local result = stmt:step()
	stmt:finalize()
	assert(result == sqlite3.DONE, self.db:errmsg())
end

---Mark every exit between two rooms, both ways, as a boundary ('door' or 'portal'), or
---clear the mark with nil.
local function mark_boundary(db, a, b, boundary)
	local stmt = assert(db:prepare([[
        UPDATE exits SET boundary = ?
        WHERE (room_id = ? AND destination_id = ?) OR (room_id = ? AND destination_id = ?)
    ]]))

	assert(stmt:bind_values(boundary, a, b, b, a) == sqlite3.OK)
	local result = stmt:step()
	stmt:finalize()
	assert(result == sqlite3.DONE, db:errmsg())
end

---Mark the exits between two rooms as a boundary without moving anything (the far side is
---already its own map, e.g. behind `enter`).
---@param a integer
---@param b integer
---@param boundary "door"|"portal"
function Memory:set_boundary(a, b, boundary)
	self:transaction(function()
		mark_boundary(self.db, a, b, boundary)
	end)
end

---Split rooms off into a new map entered at `entrance` from `outside`. The exits between the
---two become a boundary; the moved rooms lose their positions so the publisher lays them out
---again around the entrance.
---@param entrance integer First room inside.
---@param outside integer Room on the other side of the boundary.
---@param inside integer[] Every room that moves, entrance included (Placement.inside).
---@param fields table `{ boundary, type, name, realm }`; nil name means the entrance's name,
---nil realm inherits the outside map's.
---@return integer map_id
function Memory:split_map(entrance, outside, inside, fields)
	return self:transaction(function()
		mark_boundary(self.db, entrance, outside, fields.boundary)

		local stmt = assert(self.db:prepare([[
            INSERT INTO maps (name, entrance_room_id, type, realm)
            VALUES (
                COALESCE(?, (SELECT name FROM rooms WHERE id = ?)),
                ?,
                COALESCE(?, 'outdoor'),
                COALESCE(?, (SELECT m.realm FROM rooms r JOIN maps m ON m.id = r.map_id WHERE r.id = ?))
            )
        ]]))

		assert(stmt:bind_values(fields.name, entrance, entrance, fields.type, fields.realm, outside) == sqlite3.OK)
		local result = stmt:step()
		stmt:finalize()
		assert(result == sqlite3.DONE, self.db:errmsg())

		local map_id = self.db:last_insert_rowid()

		local move = assert(self.db:prepare([[
            UPDATE rooms
            SET map_id = ?, x = NULL, y = NULL, z = NULL, position_status = NULL
            WHERE id = ?
        ]]))

		for _, id in ipairs(inside) do
			assert(move:bind_values(map_id, id) == sqlite3.OK)
			local moved = move:step()
			assert(moved == sqlite3.DONE, self.db:errmsg())
			move:reset()
		end

		move:finalize()

		return map_id
	end)
end

---Undo a split: clear the boundary marks into `map_id`, delete the map and forget its rooms'
---positions so the publisher lays them out again from the neighbouring map.
---@param map_id integer
---@return integer moved Number of rooms that were in the map.
function Memory:merge_map(map_id)
	return self:transaction(function()
		local stmt = assert(self.db:prepare([[
            UPDATE exits SET boundary = NULL
            WHERE boundary IS NOT NULL
              AND (room_id IN (SELECT id FROM rooms WHERE map_id = ?)
                   OR destination_id IN (SELECT id FROM rooms WHERE map_id = ?))
        ]]))

		assert(stmt:bind_values(map_id, map_id) == sqlite3.OK)
		local result = stmt:step()
		stmt:finalize()
		assert(result == sqlite3.DONE, self.db:errmsg())

		local clear = assert(self.db:prepare([[
            UPDATE rooms
            SET map_id = NULL, x = NULL, y = NULL, z = NULL, position_status = NULL
            WHERE map_id = ?
        ]]))

		assert(clear:bind_values(map_id) == sqlite3.OK)
		result = clear:step()
		clear:finalize()
		assert(result == sqlite3.DONE, self.db:errmsg())

		local moved = self.db:changes()

		local delete = assert(self.db:prepare("DELETE FROM maps WHERE id = ?"))
		assert(delete:bind_values(map_id) == sqlite3.OK)
		result = delete:step()
		delete:finalize()
		assert(result == sqlite3.DONE, self.db:errmsg())

		return moved
	end)
end

---Close the database handle. Called by Lifecycle:cleanup() on reload.
function Memory:close()
	return self.db:close()
end

return Memory
