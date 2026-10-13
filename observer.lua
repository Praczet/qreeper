-- observer.lua
-- Collects one room observation in two phases:
--   description  lines between the header (plus compass) and the "Obvious exits" summary
--   details      lines after the summary until the prompt or the next header: statues,
--                items, monsters, other players. Some are permanent, some walk away.
-- It only buffers text; deciding when a room is finished belongs to triggers/room.lua.

local Observer = {}
Observer.__index = Observer

-- The compass decoration spans three lines; the header carries the first, so skip two.
local COMPASS_LINES_AFTER_HEADER = 2

-- Details are evidence, not a transcript. Enough for a statue and a few monsters.
local MAX_DETAIL_LINES = 12
local MAX_DETAIL_LENGTH = 200

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
		details = {},
		skip = COMPASS_LINES_AFTER_HEADER,
		summary_at = nil,
		-- Set by the room trigger when the room was stored before its details arrived.
		recorded_id = nil,
	}
end

---True while a header has been seen and the observation is still open.
function Observer:is_collecting()
	return self.pending ~= nil
end

---True once the "Obvious exits" line has been seen.
function Observer:in_details()
	return self.pending ~= nil and self.pending.summary_at ~= nil
end

---Seconds since the summary line, or nil before it.
---@param now integer
---@return integer|nil
function Observer:details_age(now)
	if not self:in_details() then
		return nil
	end

	return now - self.pending.summary_at
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

---Mark the end of the description; following lines are details.
function Observer:summary()
	if self.pending then
		self.pending.summary_at = os.time()
	end
end

---True for lines that are not room contents: blanks, prompts, and compass art, which with
---fast travel can belong to the *next* room's header (`N`, `\ | /`).
---@param text string
---@return boolean
local function is_noise(text)
	return text == "" or text:match("^>") ~= nil or text:match("^[%s\\|/%-%*NSEWUD]+$") ~= nil
end

---Add one line after the summary as a detail.
---@param line string
function Observer:add_detail(line)
	local room = self.pending

	if not room or #room.details >= MAX_DETAIL_LINES then
		return
	end

	local text = line:match("^%s*(.-)%s*$"):sub(1, MAX_DETAIL_LENGTH)

	if not is_noise(text) then
		table.insert(room.details, text)
	end
end

---The observation so far, without closing it.
---@return table|nil `{ name, exits, fingerprint, description, details }`
function Observer:snapshot()
	local room = self.pending

	if not room then
		return nil
	end

	local details = {}

	for index, line in ipairs(room.details) do
		details[index] = line
	end

	return {
		name = room.name,
		exits = room.exits,
		fingerprint = room.fingerprint,
		description = table.concat(room.lines, "\n"),
		details = details,
		recorded_id = room.recorded_id,
	}
end

---Remember that the pending room was already stored as `id` (details still arriving).
---@param id integer
function Observer:mark_recorded(id)
	if self.pending then
		self.pending.recorded_id = id
	end
end

---Close the pending observation and return its final snapshot.
---@return table|nil
function Observer:finish()
	local room = self:snapshot()
	self.pending = nil
	return room
end

---Drop the pending observation without returning it.
function Observer:cancel()
	self.pending = nil
end

return Observer
