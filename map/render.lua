-- map/render.lua
-- ASCII rendering of one level of a layout for scrollback. Draws only edges whose recorded
-- direction matches the placed geometry; irregular edges are left to the conflict list.

local Render = {}

local CELL_WIDTH = 9
local CELL_HEIGHT = 5

local RESET = "\27[0m"
local CURRENT_COLOR = "\27[1;36m" -- Bold cyan

---Write text into the sparse character canvas at (x, y).
local function put(canvas, x, y, text)
	canvas[y] = canvas[y] or {}

	for i = 1, #text do
		canvas[y][x + i - 1] = text:sub(i, i)
	end
end

---Count unexplored exits per room for the `?` marker.
local function unknown_exit_counts(layout)
	local counts = {}

	for _, exit in ipairs(layout.unknown_exits) do
		counts[exit.from] = (counts[exit.from] or 0) + 1
	end

	return counts
end

---Room label: `[@NN]` for the current room, `[NNN]` otherwise, `?` when exits are unexplored.
local function label(room_id, is_current, has_unknown)
	local marker = has_unknown and "?" or ""

	if is_current then
		return string.format("[@%02d%s]", room_id, marker)
	end

	return string.format("[%03d%s]", room_id, marker)
end

---Bresenham line between two cells, leaving endpoint labels untouched.
local function draw_line(canvas, x1, y1, x2, y2, char)
	local dx = math.abs(x2 - x1)
	local dy = math.abs(y2 - y1)

	local sx = x1 < x2 and 1 or -1
	local sy = y1 < y2 and 1 or -1

	local err = dx - dy

	local x, y = x1, y1

	while true do
		-- Don't overwrite the endpoint labels.
		if not (x == x1 and y == y1) and not (x == x2 and y == y2) then
			put(canvas, x, y, char)
		end

		if x == x2 and y == y2 then
			break
		end

		local e2 = 2 * err

		if e2 > -dy then
			err = err - dy
			x = x + sx
		end

		if e2 < dx then
			err = err + dx
			y = y + sy
		end
	end
end

---Render the current room's level as text, current room highlighted.
---@param layout table Result of Layout.build.
---@param graph table Result of Memory:get_map().
---@param current_id integer
---@return string
function Render.draw(layout, graph, current_id)
	local current = layout.rooms[current_id]
	local unknown_counts = unknown_exit_counts(layout)

	if not current then
		return "Qreeper has no location to map."
	end

	local min_x, max_x = current.x, current.x
	local min_y, max_y = current.y, current.y

	local visible = {}

	for id, room in pairs(layout.rooms) do
		if room.z == current.z then
			visible[id] = room

			min_x = math.min(min_x, room.x)
			max_x = math.max(max_x, room.x)
			min_y = math.min(min_y, room.y)
			max_y = math.max(max_y, room.y)
		end
	end

	local function center(room)
		return (room.x - min_x) * CELL_WIDTH + 5, (room.y - min_y) * CELL_HEIGHT + 3
	end

	local canvas = {}

	local offsets = {
		north = { 0, -1 },
		south = { 0, 1 },
		east = { 1, 0 },
		west = { -1, 0 },
		northeast = { 1, -1 },
		northwest = { -1, -1 },
		southeast = { 1, 1 },
		southwest = { -1, 1 },
	}

	-- Draw verified spatial connections first.
	for _, exit in ipairs(layout.connections) do
		local from = visible[exit.from]
		local to = visible[exit.to]
		local offset = offsets[exit.direction]

		if from and to and offset then
			local dx = to.x - from.x
			local dy = to.y - from.y

			if dx == offset[1] and dy == offset[2] then
				local x1, y1 = center(from)
				local x2, y2 = center(to)

				local char = "-"

				if dx == 0 then
					char = "|"
				elseif dx ~= 0 and dy ~= 0 then
					char = (dx == dy) and "\\" or "/"
				end

				draw_line(canvas, x1, y1, x2, y2, char)
			end
		end
	end

	-- Draw rooms over connection lines.
	for id, room in pairs(visible) do
		local x, y = center(room)

		local text = label(id, id == current_id, (unknown_counts[id] or 0) > 0)

		put(canvas, x - math.floor(#text / 2), y, text)
	end

	local width = (max_x - min_x) * CELL_WIDTH + 10
	local height = (max_y - min_y) * CELL_HEIGHT + 6

	local lines = {}

	for y = 1, height do
		local row = {}

		for x = 1, width do
			row[x] = (canvas[y] and canvas[y][x]) or " "
		end

		local text = table.concat(row)
		text = text:gsub("%s+$", "")
		table.insert(lines, text)
	end

	-- Remove blank lines above/below the drawing.
	while #lines > 0 and lines[1] == "" do
		table.remove(lines, 1)
	end

	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end

	local title = string.format("Qreeper's map — relative level %+d", current.z)

	local drawing = table.concat(lines, "\n")

	local current_label = label(current_id, true, (unknown_counts[current_id] or 0) > 0)

	-- Escape pattern-special characters in the label.
	local pattern = current_label:gsub("([^%w])", "%%%1")

	drawing = drawing:gsub(pattern, function(found)
		return CURRENT_COLOR .. found .. RESET
	end)

	return title .. "\n" .. drawing
end

return Render
