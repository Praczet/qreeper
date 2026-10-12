-- memory.lua
-- Qreeper's durable world record: rooms, directed exits and notes in SQLite.
--
-- This module is the only code that talks SQL. Callers get plain Lua tables back and
-- never see statements. Every query uses prepared statements with bound values.
--
-- Schema changes go through MIGRATIONS below and are tracked with `PRAGMA user_version`.
-- Never edit a migration that has shipped; append a new one instead.

local sqlite3 = require("lsqlite3")

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
}

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
---@return any, any # The callback's first two return values.
function Memory:transaction(callback)
	assert(self.db:exec("BEGIN IMMEDIATE") == sqlite3.OK, self.db:errmsg())

	local ok, first, second = pcall(callback)

	if not ok then
		self.db:exec("ROLLBACK")
		error(first, 0)
	end

	assert(self.db:exec("COMMIT") == sqlite3.OK, self.db:errmsg())

	return first, second
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

---Match an observed room to a stored one by fingerprint, or create it.
---Also records every advertised exit (destination unknown until travelled).
---
---Identity caveat: a single fingerprint match is treated as the same room. Two genuinely
---different rooms with the same name and exit list would be merged. This is a known open
---design decision, not an oversight.
---@param room table Observer result: `{ name, exits, fingerprint, description }`.
---@return integer|nil id
---@return string status `"new"`, `"known"`, or `"ambiguous"` (id is nil).
function Memory:remember_room(room)
	local db = self.db

	return self:transaction(function()
		local query = assert(db:prepare([[
            SELECT id
            FROM rooms
            WHERE fingerprint = ?
            LIMIT 2
        ]]))

		assert(query:bind_values(room.fingerprint) == sqlite3.OK)

		local matches = {}
		for row in query:nrows() do
			table.insert(matches, row.id)
		end
		query:finalize()

		if #matches > 1 then
			return nil, "ambiguous"
		end

		local id = matches[1]
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

		return id, created and "new" or "known"
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
            realm,
            area,
            level,
            x,
            y
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]]))

	local bound = stmt:bind_values(
		room.fingerprint,
		room.name,
		room.description,
		room.realm,
		room.area,
		room.level,
		room.x,
		room.y
	)

	assert(bound == sqlite3.OK, self.db:errmsg())

	local result = stmt:step()
	stmt:finalize()

	assert(result == sqlite3.DONE, self.db:errmsg())

	return self.db:last_insert_rowid()
end

---Get a room's realm, area and level, or nil if the room does not exist.
---@param id integer
---@return table|nil
function Memory:get_room_location(id)
	local stmt = assert(self.db:prepare([[
        SELECT realm, area, level
        FROM rooms
        WHERE id = ?
    ]]))

	assert(stmt:bind_values(id) == sqlite3.OK)

	local location

	for row in stmt:nrows() do
		location = {
			realm = row.realm,
			area = row.area,
			level = row.level,
		}
	end

	stmt:finalize()

	return location
end

---Set one geographical field on a room. `field` is whitelisted because it becomes SQL.
---@param id integer
---@param field "realm"|"area"|"level"
---@param value string|integer
function Memory:set_room_location(id, field, value)
	assert(field == "realm" or field == "area" or field == "level", "Invalid location field")

	local stmt = assert(self.db:prepare("UPDATE rooms SET " .. field .. " = ? WHERE id = ?"))

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

---Rooms that have at least one note, with their note counts.
---@return table[]
function Memory:get_rooms_with_notes()
	local stmt = assert(self.db:prepare([[
        SELECT
            r.id,
            r.name,
            r.realm,
            r.area,
            r.level,
            COUNT(n.id) AS note_count
        FROM rooms r
        INNER JOIN notes n ON n.room_id = r.id
        GROUP BY r.id
        ORDER BY
            r.realm,
            r.area,
            r.name,
            r.id
    ]]))

	local rooms = {}

	for row in stmt:nrows() do
		table.insert(rooms, {
			id = row.id,
			name = row.name,
			realm = row.realm,
			area = row.area,
			level = row.level,
			note_count = row.note_count,
		})
	end

	stmt:finalize()

	return rooms
end

---The whole room graph: rooms keyed by id, exits as a directed list (`to` may be nil).
---@return table `{ rooms = { [id] = room }, exits = { { from, direction, to } } }`
function Memory:get_map()
	local rooms = {}
	local exits = {}

	local room_query = assert(self.db:prepare([[
        SELECT id, name, realm, area, level, x, y
        FROM rooms
        ORDER BY id
    ]]))

	for row in room_query:nrows() do
		rooms[row.id] = {
			id = row.id,
			name = row.name,
			realm = row.realm,
			area = row.area,
			level = row.level,
			x = row.x,
			y = row.y,
		}
	end

	room_query:finalize()

	local exit_query = assert(self.db:prepare([[
        SELECT room_id, direction, destination_id
        FROM exits
        ORDER BY room_id, direction
    ]]))

	for row in exit_query:nrows() do
		table.insert(exits, {
			from = row.room_id,
			direction = row.direction,
			to = row.destination_id,
		})
	end

	exit_query:finalize()

	return {
		rooms = rooms,
		exits = exits,
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

---All known rooms for the room catalogue, ordered by id.
---@return table[]
function Memory:get_rooms()
	local stmt = assert(self.db:prepare([[
        SELECT id, name, realm, area, level
        FROM rooms
        ORDER BY id
    ]]))

	local rooms = {}

	for row in stmt:nrows() do
		table.insert(rooms, {
			id = row.id,
			name = row.name,
			realm = row.realm,
			area = row.area,
			level = row.level,
		})
	end

	stmt:finalize()

	return rooms
end

---Close the database handle. Called by Lifecycle:cleanup() on reload.
function Memory:close()
	return self.db:close()
end

return Memory
