-- publisher/placement.lua
-- First-time map positions for the QREEP snapshot. Pure function: no SQL, no Blightmud.
--
-- Rules, in order:
--   1. A room that already has a stored position never moves.
--   2. An unplaced room next to a placed one (by a recorded compass exit, in either
--      direction) takes the cell that exit implies, if that cell is free. Placed rooms are
--      never shoved around to make space. Exits confirmed both ways
--      (`A east -> B` and `B west -> A`) are followed first; one-way evidence only fills in
--      what is left. Maze-like areas (the 3Scapes forest) contradict themselves, and this
--      keeps the contradictions on the one-way edges instead of wherever BFS got first.
--   3. If the current room's whole spatial component has no placed room yet, that component
--      is laid out breadth-first from the current room and shifted east of everything
--      already placed,
--      so separate areas (the tower behind `enter`, say) cannot overlap.
--   4. Only after all of that, a room whose cell is taken (the game's geometry contradicts
--      itself, e.g. `115 west -> 117` and `118 north -> 119` both claiming one cell) goes
--      to the nearest free cell: further along its direction first, then around the cell
--      it wanted. Its exits then classify as irregular and draw as curves that leave in the
--      recorded direction. Leaving it unplaced made it invisible on the map instead.
-- Components the player is not standing in are only placed when visited (rule 3) or reached
-- from a placed room (rule 2). Unvisited is shown as unplaced, not guessed.
--
-- Maps: every position belongs to a map (a street network, a building, a dungeon). A room
-- placed by rule 2 joins the map of the room it was reached from; a component seeded by
-- rule 3 starts a new map, with the seed room as its entrance. Compass and up/down exits
-- never leave a map on their own; named exits (`enter`, `out`, ...) are the portals between
-- maps, because they are not geometry. A compass exit the player marked as a boundary
-- (`door`/`portal`, both ways) is a portal too. Cells only collide inside one map, so a building's
-- floors never fight the street's levels. Positions placed before maps existed are grouped
-- into maps by compass connectivity first (rule 0), so an existing layout keeps its shape.
-- New maps are still shifted east of everything, so a consumer drawing all maps on one
-- canvas does not stack them; coordinates are only comparable within one map.
-- A new map is named after its entrance room (the "Newbie Tower" of "Newbie Tower: Forest")
-- and remembers the map it was entered from, so the caller can inherit that map's realm.
--
-- Coordinates: east +x, south +y, up +z. They are visual, not in-game geography.
-- z follows the room's stored `level` whenever it is known, because QREEP draws one level
-- per view: two rooms on the same level must never share an (x, y) cell, whatever path led
-- to them. Up/down offsets only decide z for rooms without a level. A level-changing
-- `north` (stairs) therefore classifies as irregular, which is what it is.

local Placement = {}

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

-- Empty columns between a newly laid-out component and everything already placed.
local COMPONENT_GAP = 3

Placement.OFFSETS = OFFSETS

---Cell key for the occupancy index. `map` is a stored map id or a new-map key.
local function cell(map, x, y, z)
	return tostring(map) .. ":" .. x .. ":" .. y .. ":" .. z
end

---Sort key for an offset, so edge order is stable.
local function offset_key(offset)
	return offset[1] .. ":" .. offset[2] .. ":" .. offset[3]
end

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

---Both-way adjacency for compass exits between known rooms. Reverse links are geometry
---only; they do not claim that a reverse exit exists.
---@param mutual_only boolean Keep only exits whose opposite exit leads straight back.
---Pair key for two rooms, independent of direction.
local function pair(a, b)
	return math.min(a, b) .. ":" .. math.max(a, b)
end

---Room pairs with a door/portal mark on any exit between them.
local function boundaries(graph)
	local blocked = {}

	for _, exit in ipairs(graph.exits) do
		if exit.to and exit.boundary then
			blocked[pair(exit.from, exit.to)] = true
		end
	end

	return blocked
end

local function build_adjacency(graph, mutual_only)
	local adjacency = {}
	local recorded = {}
	local blocked = boundaries(graph)

	for _, exit in ipairs(graph.exits) do
		if exit.to and not exit.guessed then
			recorded[exit.from .. ":" .. exit.direction] = exit.to
		end
	end

	local function link(from, to, offset)
		adjacency[from] = adjacency[from] or {}
		table.insert(adjacency[from], { to = to, offset = offset, level = graph.rooms[to].level })
	end

	for _, exit in ipairs(graph.exits) do
		local offset = OFFSETS[exit.direction]
		local usable = offset
			and exit.to
			and not exit.guessed
			and exit.from ~= exit.to
			and graph.rooms[exit.from]
			and graph.rooms[exit.to]
			and not blocked[pair(exit.from, exit.to)]

		if usable and mutual_only then
			usable = recorded[exit.to .. ":" .. OPPOSITE[exit.direction]] == exit.from
		end

		if usable then
			link(exit.from, exit.to, offset)
			link(exit.to, exit.from, { -offset[1], -offset[2], -offset[3] })
		end
	end

	-- Stable order, so the same graph always produces the same layout.
	for _, edges in pairs(adjacency) do
		table.sort(edges, function(a, b)
			if a.to ~= b.to then
				return a.to < b.to
			end

			return offset_key(a.offset) < offset_key(b.offset)
		end)
	end

	return adjacency
end

---Breadth-first spread from the rooms in `queue`, writing into `positions`/`occupied`.
---@return integer[] ids Newly positioned rooms, in placement order.
---Nearest free cell for a room whose exit-implied cell (x, y, z) is taken. Order: further
---along the exit's direction (2 and 3 steps), then the ring around the wanted cell, then the
---ring two cells out. Same z: the floor is not negotiable.
---@return integer|nil x
---@return integer|nil y
local function displaced_cell(occupied, map, x, y, z, offset)
	local candidates = {}

	if offset[1] ~= 0 or offset[2] ~= 0 then
		table.insert(candidates, { x + offset[1], y + offset[2] })
		table.insert(candidates, { x + offset[1] * 2, y + offset[2] * 2 })
	end

	for radius = 1, 2 do
		for dy = -radius, radius do
			for dx = -radius, radius do
				if math.max(math.abs(dx), math.abs(dy)) == radius then
					table.insert(candidates, { x + dx, y + dy })
				end
			end
		end
	end

	for _, candidate in ipairs(candidates) do
		if not occupied[cell(map, candidate[1], candidate[2], z)] then
			return candidate[1], candidate[2]
		end
	end

	return nil
end

---@param displace boolean Allow rule 4 (nearest free cell) when the wanted cell is taken.
---@param stored_map table<integer, integer> Room id -> map id it already belongs to; such a
---room keeps that map wherever the layout reaches it from.
local function spread_once(adjacency, queue, positions, occupied, displace, stored_map)
	local added = {}
	local head = 1

	while head <= #queue do
		local id = queue[head]
		head = head + 1

		local from = positions[id]

		for _, edge in ipairs(adjacency[id] or {}) do
			if not positions[edge.to] then
				local x = from.x + edge.offset[1]
				local y = from.y + edge.offset[2]
				-- Stored level wins over the path-derived height; see the header.
				local z = edge.level ~= nil and edge.level or from.z + edge.offset[3]
				local map = stored_map[edge.to] or from.map
				local key = cell(map, x, y, z)

				if occupied[key] and displace then
					local free_x, free_y = displaced_cell(occupied, map, x, y, z, edge.offset)

					if free_x then
						x, y = free_x, free_y
						key = cell(map, x, y, z)
					end
				end

				if not occupied[key] then
					positions[edge.to] = { x = x, y = y, z = z, map = map }
					occupied[key] = edge.to
					table.insert(added, edge.to)
					table.insert(queue, edge.to)
				end
			end
		end
	end

	return added
end

---Spread along confirmed (mutual) exits first, then along everything else.
---@param adjacency table `{ mutual = ..., all = ... }`
---@param seeds integer[] Rooms to start from, already in `positions`.
---@return integer[] ids Newly positioned rooms, in placement order.
local function spread(adjacency, seeds, positions, occupied, stored_map)
	local added = {}
	-- Copies, not table.unpack: unpack has a result limit that big worlds would hit.
	local queue = {}
	local everyone = {}

	for _, id in ipairs(seeds) do
		table.insert(queue, id)
		table.insert(everyone, id)
	end

	for _, id in ipairs(spread_once(adjacency.mutual, queue, positions, occupied, false, stored_map)) do
		table.insert(added, id)
	end

	-- Second pass restarts from every placed room so one-way edges can reach leftovers.
	for _, id in ipairs(added) do
		table.insert(everyone, id)
	end

	local all_pass = spread_once(adjacency.all, everyone, positions, occupied, false, stored_map)

	for _, id in ipairs(all_pass) do
		table.insert(added, id)
		table.insert(everyone, id)
	end

	-- Last pass: contradictions go to the nearest free cell instead of staying invisible.
	for _, id in ipairs(spread_once(adjacency.all, everyone, positions, occupied, true, stored_map)) do
		table.insert(added, id)
	end

	return added
end

---True when any room spatially connected to `start_id` already has a position.
---@return boolean placed
---@return integer|nil map Lowest-id room's stored map in the component, when not placed.
local function component_has_position(adjacency, start_id, positions, stored_map)
	local seen = { [start_id] = true }
	local queue = { start_id }
	local head = 1
	local map, map_owner

	while head <= #queue do
		local id = queue[head]
		head = head + 1

		if positions[id] then
			return true
		end

		if stored_map[id] and (map_owner == nil or id < map_owner) then
			map, map_owner = stored_map[id], id
		end

		for _, edge in ipairs(adjacency[id] or {}) do
			if not seen[edge.to] then
				seen[edge.to] = true
				table.insert(queue, edge.to)
			end
		end
	end

	return false, map
end

---Default name for a map entered at `room`: the "Area" of "Area: Room", else the room name.
function Placement.map_name(room)
	local name = room.name or ("#" .. tostring(room.id))
	return name:match("^%s*(.-)%s*:%s*%S") or name
end

---Rule 0: give positioned rooms without a map one. Each compass-connected group of them
---joins a neighbouring room's map if it touches one, otherwise becomes a new map entered at
---its lowest id. Coordinates are kept as they are.
---@return table[] adopted `{ id, map }`
local function adopt_unmapped(adjacency, ids, positions, new_map)
	local adopted = {}

	for _, start in ipairs(ids) do
		if positions[start] and positions[start].map == nil then
			local group = { start }
			local seen = { [start] = true }
			local map
			local head = 1

			while head <= #group do
				local id = group[head]
				head = head + 1

				for _, edge in ipairs(adjacency[id] or {}) do
					local neighbour = positions[edge.to]

					if neighbour and not seen[edge.to] then
						seen[edge.to] = true

						if neighbour.map == nil then
							table.insert(group, edge.to)
						else
							map = map or neighbour.map
						end
					end
				end
			end

			-- `ids` is sorted and every lower id was handled already, so `start` is the lowest.
			map = map or new_map(start)

			for _, id in ipairs(group) do
				positions[id].map = map
				table.insert(adopted, { id = id, map = map })
			end
		end
	end

	return adopted
end

---Work out positions for rooms that do not have one yet.
---@param graph table Memory:get_map() result; rooms may carry stored x/y/z and map_id.
---@param current_id integer|nil Where the player is, used only to seed a new component.
---@return table[] placements `{ id, x, y, z, map }` for newly placed rooms only.
---@return table[] maps New maps `{ key, entrance, name, parent }`; `parent` is the map of a
---placed room linked to the entrance by any exit (nil if none). `map` fields elsewhere are either a
---stored map id (integer) or one of these keys (string) until the caller stores them.
---@return table[] adopted `{ id, map }` for rooms that had a position but no map.
function Placement.place(graph, current_id)
	local adjacency = {
		mutual = build_adjacency(graph, true),
		all = build_adjacency(graph, false),
	}
	local positions = {}
	local occupied = {}
	local ids = {}
	local maps = {}

	local function new_map(entrance, parent)
		local key = "new:" .. (#maps + 1)
		table.insert(maps, { key = key, entrance = entrance, name = Placement.map_name(graph.rooms[entrance]), parent = parent })
		return key
	end

	local stored_map = {}

	for id, room in pairs(graph.rooms) do
		table.insert(ids, id)
		stored_map[id] = room.map_id

		if room.x ~= nil and room.y ~= nil and room.z ~= nil then
			positions[id] = { x = room.x, y = room.y, z = room.z, map = room.map_id }
		end
	end

	table.sort(ids)

	local adopted = adopt_unmapped(adjacency.all, ids, positions, new_map)

	for id, position in pairs(positions) do
		occupied[cell(position.map, position.x, position.y, position.z)] = id
	end

	local added = {}

	-- Rule 2: grow from every stored position, lowest id first.
	local queue = {}
	for _, id in ipairs(ids) do
		if positions[id] then
			table.insert(queue, id)
		end
	end

	for _, id in ipairs(spread(adjacency, queue, positions, occupied, stored_map)) do
		table.insert(added, id)
	end

	-- Rule 3: seed the current room's component when none of it is placed.
	local component_placed, component_map = true, nil

	if current_id and graph.rooms[current_id] then
		component_placed, component_map = component_has_position(adjacency.all, current_id, positions, stored_map)
	end

	if not component_placed then
		local seed_z = graph.rooms[current_id].level or 0
		-- A split (Memory:split_map) or an earlier layout (before qreeper:relayout) already
		-- gave this component its map; otherwise start one, remembering the map on the other
		-- side of the exit that leads here.
		local map = stored_map[current_id] or component_map

		if not map then
			local parent

			for _, exit in ipairs(graph.exits) do
				local other = exit.from == current_id and exit.to or exit.to == current_id and exit.from or nil

				if other and other ~= current_id and positions[other] then
					parent = positions[other].map
					break
				end
			end

			map = new_map(current_id, parent)
		end

		local trial = { [current_id] = { x = 0, y = 0, z = seed_z, map = map } }
		local trial_occupied = { [cell(map, 0, 0, seed_z)] = current_id }
		local trial_ids = { current_id }

		for _, id in ipairs(spread(adjacency, { current_id }, trial, trial_occupied, stored_map)) do
			table.insert(trial_ids, id)
		end


		local shift = 0
		local max_x

		for _, position in pairs(positions) do
			max_x = max_x and math.max(max_x, position.x) or position.x
		end

		if max_x then
			local min_x

			for _, position in pairs(trial) do
				min_x = min_x and math.min(min_x, position.x) or position.x
			end

			shift = max_x + COMPONENT_GAP - min_x
		end

		for _, id in ipairs(trial_ids) do
			local position = trial[id]
			positions[id] = { x = position.x + shift, y = position.y, z = position.z, map = position.map }
			occupied[cell(position.map, position.x + shift, position.y, position.z)] = id
			table.insert(added, id)
		end
	end

	local placements = {}

	for _, id in ipairs(added) do
		local position = positions[id]
		table.insert(placements, { id = id, x = position.x, y = position.y, z = position.z, map = position.map })
	end

	return placements, maps, adopted
end

---Rooms that move with `entrance` when it is split off from `outside`: everything in the
---entrance's map reachable from it by compass/up-down exits without stepping straight back
---to `outside` or across a boundary. Rooms of other maps are never taken along. Nil when `outside` is still reachable another way, because then there is no one
---door to split at.
---@param graph table Memory:get_map() result.
---@param entrance integer
---@param outside integer
---@return integer[]|nil ids Sorted, entrance included.
function Placement.inside(graph, entrance, outside)
	local adjacency = build_adjacency(graph, false)
	local map = graph.rooms[entrance].map_id
	local seen = { [entrance] = true }
	local queue = { entrance }
	local head = 1

	while head <= #queue do
		local id = queue[head]
		head = head + 1

		for _, edge in ipairs(adjacency[id] or {}) do
			local door = id == entrance and edge.to == outside

			if not door and not seen[edge.to] and graph.rooms[edge.to].map_id == map then
				if edge.to == outside then
					return nil
				end

				seen[edge.to] = true
				table.insert(queue, edge.to)
			end
		end
	end

	table.sort(queue)

	return queue
end

---Classify a directed exit for the snapshot `geometry` field, using final positions.
---@param exit table `{ from, direction, to }`
---@param positions table<integer, table> Room id -> `{ x, y, z, map }`.
---@return "regular"|"irregular"|"named"|"unknown"|"unplaced"
---A compass exit between two maps is irregular: their coordinates are not comparable.
function Placement.geometry(exit, positions)
	if exit.to == nil then
		return "unknown"
	end

	local offset = OFFSETS[exit.direction]

	if not offset then
		return "named"
	end

	local from = positions[exit.from]
	local to = positions[exit.to]

	if not from or not to then
		return "unplaced"
	end

	if from.map == to.map and to.x == from.x + offset[1] and to.y == from.y + offset[2] and to.z == from.z + offset[3] then
		return "regular"
	end

	return "irregular"
end

return Placement
