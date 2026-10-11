local sqlite3 = require("lsqlite3")

local Memory = {}
Memory.__index = Memory

function Memory.new(path)
	local db = sqlite3.open(path)

	assert(db, "Qreeper memory could not be opened")

	local self = setmetatable({
		db = db,
	}, Memory)

	assert(db:exec("PRAGMA foreign_keys = ON") == sqlite3.OK, db:errmsg())

	return self
end

function Memory:remember_room(room)
	local db = self.db

	-- Find existing rooms with the same fingerprint.
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
		-- Update the last visit.
		local stmt = assert(db:prepare([[
            UPDATE rooms
            SET last_seen_at = CURRENT_TIMESTAMP
            WHERE id = ?
        ]]))

		assert(stmt:bind_values(id) == sqlite3.OK)
		local result = stmt:step()
		stmt:finalize()
		assert(result == sqlite3.DONE, db:errmsg())
	else
		-- A newly discovered room.
		id = self:add_room(room)
		created = true
	end

	-- Remember all observed exits.
	for _, direction in ipairs(room.exits) do
		local stmt = assert(db:prepare([[
            INSERT OR IGNORE INTO exits (room_id, direction)
            VALUES (?, ?)
        ]]))

		assert(stmt:bind_values(id, direction) == sqlite3.OK)
		local result = stmt:step()
		stmt:finalize()
		assert(result == sqlite3.DONE, db:errmsg())
	end

	return id, created and "new" or "known"
end

function Memory:initialize()
	local result = self.db:exec([[
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
    ]])

	assert(result == sqlite3.OK, self.db:errmsg())
end

function Memory:add_room(room)
	local stmt = assert(self.db:prepare([[
        INSERT INTO rooms (
            fingerprint, name, realm, area, level, x, y
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]]))

	assert(
		stmt:bind_values(room.fingerprint, room.name, room.realm, room.area, room.level, room.x, room.y) == sqlite3.OK
	)

	local result = stmt:step()
	stmt:finalize()

	assert(result == sqlite3.DONE, self.db:errmsg())

	return self.db:last_insert_rowid()
end

function Memory:close()
	return self.db:close()
end

return Memory
