-- aliases/map.lua
-- `qreeper:map`: draws the current level of the current room's spatial component in
-- scrollback, followed by conflicts, unexplored exits and latest notes.
-- The drawing is a view computed on demand (map/layout.lua); nothing is stored.

local Whisper = require("whisper")
local Layout = require("map.layout")
local Render = require("map.render")
local NOTE_COLOR = "\27[2;33m"
local RESET = "\27[0m"

local MapAliases = {}

---Register the map alias.
---@param qreeper table Lifecycle instance that owns the alias.
---@param memory table
---@param tracker table
function MapAliases.register(qreeper, memory, tracker)
	qreeper:add_alias("^qreeper:map$", function()
		local current_id = tracker.current_room

		if not current_id then
			Whisper.say("I cannot draw a map without knowing where we are. " .. "Look around first.")
			return
		end

		local ok, result = pcall(function()
			local graph = memory:get_map()
			local layout = Layout.build(graph, current_id)
			local drawing = Render.draw(layout, graph, current_id)

			return {
				drawing = drawing,
				layout = layout,
				graph = graph,
			}
		end)

		if not ok then
			Whisper.say("My cartographic talents have encountered an obstacle.")
			blight.output("Qreeper map error: " .. tostring(result))
			return
		end

		for line in (result.drawing .. "\n"):gmatch("(.-)\n") do
			blight.output(line)
		end

		local placed = 0

		for _ in pairs(result.layout.rooms) do
			placed = placed + 1
		end

		blight.output("")
		blight.output(
			string.format(
				"Rooms positioned: %d | Unknown exits: %d | Spatial conflicts: %d",
				placed,
				#result.layout.unknown_exits,
				#result.layout.conflicts
			)
		)

		if #result.layout.conflicts > 0 then
			blight.output("Some paths contradict the calculated layout.")

			for i, conflict in ipairs(result.layout.conflicts) do
				if i > 5 then
					blight.output("  ... more conflicts omitted")
					break
				end

				blight.output(
					string.format(
						"  Room #%s, %s -> room #%s (%s)",
						tostring(conflict.from),
						tostring(conflict.direction),
						tostring(conflict.to),
						tostring(conflict.type)
					)
				)
			end
		end

		-- Collect rooms on the current displayed level.
		local origin = result.layout.rooms[current_id]
		local visible_ids = {}

		for id, room in pairs(result.layout.rooms) do
			if room.z == origin.z then
				table.insert(visible_ids, id)
			end
		end

		table.sort(visible_ids)

		-- Index unexplored exits by room.
		local unknown_by_room = {}

		for _, exit in ipairs(result.layout.unknown_exits) do
			unknown_by_room[exit.from] = unknown_by_room[exit.from] or {}

			table.insert(unknown_by_room[exit.from], exit.direction)
		end

		blight.output("")
		blight.output("Rooms:")

		local latest_notes = memory:get_latest_notes()

		for _, id in ipairs(visible_ids) do
			local room = result.graph.rooms[id]
			local prefix = id == current_id and "@" or " "
			local directions = unknown_by_room[id] or {}
			local note = latest_notes[id]

			table.sort(directions)

			blight.output(string.format("  %s%02d  %s", prefix, id, room.name))

			if #directions > 0 then
				blight.output("       Unknown: " .. table.concat(directions, ", "))
			end

			if note then
				blight.output(NOTE_COLOR .. "       Note: " .. note .. RESET)
			end
		end

		blight.output("")
		blight.output(string.format("Visible: %d | Other levels: %d", #visible_ids, placed - #visible_ids))

		blight.output("? = One or more unexplored exits")

		Whisper.say("Behold, a map. Its accuracy is improving with every disaster.")
	end)
end

return MapAliases
