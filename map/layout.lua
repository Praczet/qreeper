-- map/layout.lua
-- Derives approximate grid coordinates from the room graph. This is a *view*, recomputed on
-- every call and never stored: adding an edge can move rooms placed by an earlier call.
--
-- Placement is a deterministic breadth-first walk from the lowest room id in the current
-- room's spatial component. Only that component is placed. Collisions leave a room unplaced
-- and contradicting edges are reported as conflicts instead of bending the grid.

local Layout = {}

-- Coordinate system:
-- east  = +x
-- south = +y
-- up    = +z

local OFFSETS = {
	north = { 0, -1, 0 },
	south = { 0, 1, 0 },
	east = { 1, 0, 0 },
	west = { -1, 0, 0 },

	northeast = { 1, -1, 0 },
	northwest = { -1, -1, 0 },
	southeast = { 1, 1, 0 },
	southwest = { -1, 1, 0 },

	up = { 0, 0, 1 },
	down = { 0, 0, -1 },
}

---Hash key for an occupied grid cell.
local function position_key(x, y, z)
	return table.concat({ x, y, z }, ":")
end

---True when two placed rooms occupy the same cell.
local function same_position(a, b)
	return a.x == b.x and a.y == b.y and a.z == b.z
end

---Stable edge order so placement does not depend on table iteration order.
local function compare_edges(a, b)
	if a.to ~= b.to then
		return a.to < b.to
	end

	if a.direction ~= b.direction then
		return a.direction < b.direction
	end

	return a.from < b.from
end

---Build a bidirectional spatial adjacency index.
---Reverse edges are used only for calculating positions.
---They do not represent discovered reverse exits.
local function build_adjacency(graph)
	local adjacency = {}

	local function add_edge(from, to, direction, offset)
		adjacency[from] = adjacency[from] or {}

		table.insert(adjacency[from], {
			from = from,
			to = to,
			direction = direction,
			offset = offset,
		})
	end

	for _, exit in ipairs(graph.exits) do
		local offset = OFFSETS[exit.direction]

		if offset and exit.to and graph.rooms[exit.from] and graph.rooms[exit.to] then
			add_edge(exit.from, exit.to, exit.direction, offset)

			-- Infer reverse geometry, not a reverse exit.
			add_edge(exit.to, exit.from, exit.direction, {
				-offset[1],
				-offset[2],
				-offset[3],
			})
		end
	end

	for _, edges in pairs(adjacency) do
		table.sort(edges, compare_edges)
	end

	return adjacency
end

---Find the lowest room ID in the spatially connected region.
---@param adjacency table
---@param origin_id integer
---@return integer
local function find_anchor(adjacency, origin_id)
	local visited = {
		[origin_id] = true,
	}

	local queue = { origin_id }
	local head = 1
	local anchor = origin_id

	while head <= #queue do
		local id = queue[head]
		head = head + 1

		if id < anchor then
			anchor = id
		end

		for _, edge in ipairs(adjacency[id] or {}) do
			if not visited[edge.to] then
				visited[edge.to] = true
				table.insert(queue, edge.to)
			end
		end
	end

	return anchor
end

---Build a stable spatial layout from a room graph.
---@param graph table Result of Memory:get_map()
---@param origin_id integer Current room ID
---@return table
function Layout.build(graph, origin_id)
	local result = {
		origin = origin_id,
		anchor = nil,
		rooms = {},
		connections = {},
		unknown_exits = {},
		conflicts = {},
		unplaced = {},
	}

	if not graph.rooms[origin_id] then
		return result
	end

	local adjacency = build_adjacency(graph)

	-- Choose a stable anchor, independent of player position.
	local anchor = find_anchor(adjacency, origin_id)
	result.anchor = anchor

	-- Only positioned rooms enter the queue.
	local queue = { anchor }
	local head = 1

	local visited = {
		[anchor] = true,
	}

	local occupied = {
		[position_key(0, 0, 0)] = anchor,
	}

	result.rooms[anchor] = {
		id = anchor,
		x = 0,
		y = 0,
		z = 0,
	}

	-- Deterministic breadth-first spatial placement.
	while head <= #queue do
		local current_id = queue[head]
		head = head + 1

		local current = result.rooms[current_id]

		for _, edge in ipairs(adjacency[current_id] or {}) do
			local destination = edge.to
			local offset = edge.offset

			local expected = {
				id = destination,
				x = current.x + offset[1],
				y = current.y + offset[2],
				z = current.z + offset[3],
			}

			local existing = result.rooms[destination]

			if not existing then
				local key = position_key(expected.x, expected.y, expected.z)

				local occupant = occupied[key]

				if occupant and occupant ~= destination then
					-- Two rooms want the same position.
					result.unplaced[destination] = true
				else
					result.rooms[destination] = expected
					occupied[key] = destination
					result.unplaced[destination] = nil

					if not visited[destination] then
						visited[destination] = true
						table.insert(queue, destination)
					end
				end
			end
		end
	end

	-- Evaluate the original directed connections.
	-- Do not treat inferred reverse geometry as a real exit.
	for _, exit in ipairs(graph.exits) do
		local from = result.rooms[exit.from]

		if from then
			if not exit.to then
				table.insert(result.unknown_exits, exit)
			elseif not graph.rooms[exit.to] then
				table.insert(result.conflicts, {
					type = "missing-room",
					from = exit.from,
					to = exit.to,
					direction = exit.direction,
				})
			else
				table.insert(result.connections, exit)

				local offset = OFFSETS[exit.direction]
				local destination = result.rooms[exit.to]

				if not offset then
					-- Named exits remain graph connections,
					-- but have no geometric offset.
					if not destination then
						result.unplaced[exit.to] = true
					end
				elseif not destination then
					result.unplaced[exit.to] = true

					table.insert(result.conflicts, {
						type = "unplaced",
						from = exit.from,
						to = exit.to,
						direction = exit.direction,
					})
				else
					local expected = {
						id = exit.to,
						x = from.x + offset[1],
						y = from.y + offset[2],
						z = from.z + offset[3],
					}

					if not same_position(destination, expected) then
						table.insert(result.conflicts, {
							type = "position",
							from = exit.from,
							to = exit.to,
							direction = exit.direction,
							expected = expected,
							actual = destination,
						})
					end
				end
			end
		end
	end

	-- Mark every room that belongs to the spatial component
	-- but could not be positioned without a collision.
	local component_seen = { [anchor] = true }
	local component_queue = { anchor }
	local component_head = 1

	while component_head <= #component_queue do
		local id = component_queue[component_head]
		component_head = component_head + 1

		for _, edge in ipairs(adjacency[id] or {}) do
			if not component_seen[edge.to] then
				component_seen[edge.to] = true
				table.insert(component_queue, edge.to)
			end
		end
	end

	for id in pairs(component_seen) do
		if not result.rooms[id] then
			result.unplaced[id] = true
		end
	end

	return result
end

return Layout
