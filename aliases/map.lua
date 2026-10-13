-- aliases/map.lua
-- `qreeper:map`: draws the current level of the current room's spatial component in
-- scrollback, followed by conflicts, unexplored exits and latest notes.
-- The drawing is a view computed on demand (map/layout.lua); nothing is stored.
--
-- `qreeper:relayout`: forgets the stored QREEP map positions and republishes, so the
-- current area is laid out again. Use after repairing exits or when the layout looks daft.
--
-- `qreeper:check`: lists room pairs that record the same direction both ways (merged
-- lookalikes) with the forget-room fix.
--
-- `qreeper:forget-room N`: deletes a misidentified room (two places merged into one) and
-- its outgoing exits, so walking the area again records them separately. Refuses rooms
-- with notes.

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
---@param publisher table Snapshot publisher, for `qreeper:relayout`.
function MapAliases.register(qreeper, memory, tracker, publisher)
	qreeper:add_alias("^qreeper:forget-room\\s+#?(\\d+)$", function(matches)
		local id = tonumber(matches[2])
		local ok, deleted, reason, count = pcall(function()
			return memory:forget_room(id)
		end)

		if not ok then
			Whisper.say("Forgetting #" .. tostring(id) .. " went wrong. Your memory is intact, sadly.")
			blight.output("Qreeper forget-room error: " .. tostring(deleted))
			return
		end

		if not deleted and reason == "missing" then
			Whisper.say("There is no #" .. id .. " to forget. Easiest request yet.")
			return
		end

		if not deleted and reason == "notes" then
			Whisper.say("#" .. id .. " has " .. count .. " note(s). Forget those first with qreeper:forget-note, if you mean it.")
			return
		end

		if tracker.current_room == id then
			tracker:lose_position()
		end

		publisher:publish()
		Whisper.say("#" .. id .. " is forgotten. Walk there again and I'll tell the twins apart this time.")
	end)

	qreeper:add_alias("^qreeper:check$", function()
		local ok, found = pcall(function()
			return memory:find_suspicious_pairs()
		end)

		if not ok then
			Whisper.say("My self-examination was interrupted.")
			blight.output("Qreeper check error: " .. tostring(found))
			return
		end

		if #found == 0 then
			Whisper.say("No rooms contradict themselves. Today.")
			return
		end

		blight.output("Qreeper check — rooms that record the same direction both ways (likely merged lookalikes):")

		local ids = {}
		local seen = {}

		for _, pair in ipairs(found) do
			blight.output(string.format("  #%d %s  <%s>  #%d %s", pair.a, pair.a_name, pair.direction, pair.b, pair.b_name))

			for _, id in ipairs({ pair.a, pair.b }) do
				if not seen[id] then
					seen[id] = true
					table.insert(ids, id)
				end
			end
		end

		table.sort(ids)
		blight.output("  Fix: qreeper:forget-room N for each of: " .. table.concat(ids, ", ") .. " — then walk those streets again.")
		Whisper.say(#found .. " suspicious connection(s). Details in scrollback.")
	end)

	qreeper:add_alias("^qreeper:relayout$", function()
		local ok, cleared = pcall(function()
			return memory:clear_positions()
		end)

		if not ok then
			Whisper.say("The old map refuses to be forgotten.")
			blight.output("Qreeper relayout error: " .. tostring(cleared))
			return
		end

		publisher:publish()
		Whisper.say("Forgot " .. cleared .. " positions. Other areas return when you visit them.")
	end)

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
