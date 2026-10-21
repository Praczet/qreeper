-- navigator.lua
-- Route finding over the recorded room graph. Pure Lua: takes Memory:get_map() output.
--
-- Two kinds of step:
--   walked    a directed exit with a recorded destination. Cost 1.
--   probable  the way back along a walked compass/up/down exit, used only when the far room
--             *advertises* the opposite exit and it is still unexplored. Walking down into a
--             new room that lists `up` makes `up` the probable way back. Cost PROBABLE_COST,
--             so a walked route wins unless it is much longer.
-- Probable steps exist only inside a route. Nothing is written back; the next real move
-- records whatever the exit actually does, and the journey re-plans from there.
--
-- Routes are cheapest by cost, ties broken by direction name, so the same graph always gives
-- the same route.

local Navigator = {}

-- A probable step costs this many walked steps.
Navigator.PROBABLE_COST = 3

local SHORT = {
	north = "n",
	south = "s",
	east = "e",
	west = "w",
	northeast = "ne",
	northwest = "nw",
	southeast = "se",
	southwest = "sw",
	up = "u",
	down = "d",
}

local OPPOSITE = {
	north = "south",
	south = "north",
	east = "west",
	west = "east",
	northeast = "southwest",
	southwest = "northeast",
	northwest = "southeast",
	southeast = "northwest",
	up = "down",
	down = "up",
}

---The command to type for a direction: compass and up/down abbreviated, named exits whole.
---@param direction string
---@return string
function Navigator.command(direction)
	return SHORT[direction] or direction
end

---Directed adjacency `{ [from] = { { direction, to, cost, probable } } }`, sorted for stable routes.
---@param graph table
---@return table
local function build_adjacency(graph)
	local adjacency = {}
	-- `exits_by_room[id][direction] = destination or false` for "advertised, unexplored".
	local exits_by_room = {}

	for _, exit in ipairs(graph.exits) do
		exits_by_room[exit.from] = exits_by_room[exit.from] or {}
		exits_by_room[exit.from][exit.direction] = exit.to or false
	end

	local function add(from, direction, to, probable)
		adjacency[from] = adjacency[from] or {}
		table.insert(adjacency[from], {
			direction = direction,
			to = to,
			cost = probable and Navigator.PROBABLE_COST or 1,
			probable = probable,
		})
	end

	for _, exit in ipairs(graph.exits) do
		if exit.to and graph.rooms[exit.from] and graph.rooms[exit.to] and exit.from ~= exit.to then
			add(exit.from, exit.direction, exit.to, exit.guessed == true)

			local back = OPPOSITE[exit.direction]

			if back and exits_by_room[exit.to] and exits_by_room[exit.to][back] == false then
				add(exit.to, back, exit.from, true)
			end
		end
	end

	for _, edges in pairs(adjacency) do
		table.sort(edges, function(a, b)
			if a.cost ~= b.cost then
				return a.cost < b.cost
			end

			if a.direction ~= b.direction then
				return a.direction < b.direction
			end

			return a.to < b.to
		end)
	end

	return adjacency
end

---Cheapest route from `from_id` to `to_id`.
---@param graph table Memory:get_map() result.
---@param from_id integer
---@param to_id integer
---@return table[]|nil steps `{ { direction, from, to, probable } }` in travel order; `{}` when
---already there; nil when no route exists even with probable steps.
function Navigator.route(graph, from_id, to_id)
	if from_id == to_id then
		return {}
	end

	if not graph.rooms[from_id] or not graph.rooms[to_id] then
		return nil
	end

	local adjacency = build_adjacency(graph)
	local best = { [from_id] = 0 }
	local previous = {}
	local done = {}

	-- Dial's algorithm: costs are small integers, so a bucket per distance replaces a heap.
	local buckets = { [0] = { from_id } }
	local distance = 0
	local highest = 0

	while distance <= highest do
		local bucket = buckets[distance]

		if bucket and #bucket > 0 then
			local id = table.remove(bucket, 1)

			if not done[id] and best[id] == distance then
				done[id] = true

				if id == to_id then
					local steps = {}
					local cursor = to_id

					while previous[cursor] do
						local step = previous[cursor]
						table.insert(steps, 1, { direction = step.direction, from = step.from, to = cursor, probable = step.probable })
						cursor = step.from
					end

					return steps
				end

				for _, edge in ipairs(adjacency[id] or {}) do
					local candidate = distance + edge.cost

					if not done[edge.to] and (best[edge.to] == nil or candidate < best[edge.to]) then
						best[edge.to] = candidate
						previous[edge.to] = { from = id, direction = edge.direction, probable = edge.probable }
						buckets[candidate] = buckets[candidate] or {}
						table.insert(buckets[candidate], edge.to)
						highest = math.max(highest, candidate)
					end
				end
			end
		else
			distance = distance + 1
		end
	end

	return nil
end

---Comma-separated commands for a route, e.g. `u?, s, enter`. `?` marks a probable step.
---@param steps table[]
---@return string
function Navigator.describe(steps)
	local commands = {}

	for _, step in ipairs(steps) do
		table.insert(commands, Navigator.command(step.direction) .. (step.probable and "?" or ""))
	end

	return table.concat(commands, ", ")
end

---True when any step of the route is probable rather than walked.
---@param steps table[]
---@return boolean
function Navigator.has_probable(steps)
	for _, step in ipairs(steps) do
		if step.probable then
			return true
		end
	end

	return false
end

return Navigator
