-- observer.lua
-- Collects one room's description between its header and the line that ends it.
-- It only buffers text; deciding when a room is finished belongs to triggers/room.lua.

local Observer = {}
Observer.__index = Observer

-- The compass decoration spans three lines; the header carries the first, so skip two.
local COMPASS_LINES_AFTER_HEADER = 2

---Create an observer with nothing pending.
function Observer.new()
	return setmetatable({
		pending = nil,
	}, Observer)
end

---Start collecting a description for a freshly parsed header.
---@param room table `{ name, exits, fingerprint }` from parse_room.
function Observer:begin(room)
	self.pending = {
		name = room.name,
		exits = room.exits,
		fingerprint = room.fingerprint,
		lines = {},
		skip = COMPASS_LINES_AFTER_HEADER,
	}
end

---True while a header has been seen and its description is still open.
function Observer:is_collecting()
	return self.pending ~= nil
end

---Add one output line to the pending description, skipping compass lines and blanks.
---@param line string
function Observer:add_line(line)
	local room = self.pending

	if not room then
		return
	end

	-- Skip the lower two lines of the compass.
	if room.skip > 0 then
		room.skip = room.skip - 1
		return
	end

	local text = line:match("^%s*(.-)%s*$")

	if text ~= "" then
		table.insert(room.lines, text)
	end
end

---Close the pending observation and return it with `description` joined from its lines.
---@return table|nil
function Observer:finish()
	if not self.pending then
		return nil
	end

	local room = self.pending
	self.pending = nil

	room.description = table.concat(room.lines, "\n")
	room.lines = nil
	room.skip = nil

	return room
end

---Drop the pending observation without returning it.
function Observer:cancel()
	self.pending = nil
end

return Observer
