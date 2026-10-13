-- aliases/location.lua
-- Manual geography. Level belongs to the room; type, name and realm belong to its map.
--
--   qreeper:where               the current room: id, name, level, map, realm, exits, notes
--   qreeper:level N             set the current room's level
--   qreeper:realm NAME          set the current map's realm
--   qreeper:map-type            show the current map and the known types
--   qreeper:map-type TYPE [NAME]
--                               "this is a building (called NAME)". Run it in the first room
--                               inside. If that room is still part of the outside map (you
--                               came in by a compass exit), it is split off into a new map at
--                               the exit you just used, which becomes a door. A split that
--                               takes most of the map asks first: repeat the command within
--                               a minute to confirm.
--   qreeper:map-type-add NAME   add a map type (sewer, tower, ...)
--   qreeper:portal REALM        like map-type, but the exit you just used is a portal into
--                               REALM; maps entered from here inherit it
--   qreeper:map-merge           undo a split: the current map rejoins its neighbour

local Whisper = require("whisper")
local Placement = require("publisher.placement")

local LocationAliases = {}

-- How long a refused big split waits for the same command again.
local CONFIRM_SECONDS = 60

---Strip leading and trailing whitespace.
local function trim(value)
	return (value or ""):match("^%s*(.-)%s*$")
end

---One-line description of a map for scrollback.
local function describe(map)
	return string.format("#%d %s (%s, realm %s)", map.id, map.name, map.type, map.realm or "?")
end

---@param qreeper table Lifecycle instance that owns the aliases.
---@param memory table
---@param tracker table
---@param publisher table Snapshot publisher; maps and levels appear on the QREEP map.
function LocationAliases.register(qreeper, memory, tracker, publisher)
	-- The big split waiting for confirmation: `{ room, outside, count, at }`.
	local pending_split
	---Run `callback(room_id)` with a known current room, reporting errors in character.
	local function in_room(callback)
		local room_id = tracker.current_room

		if not room_id then
			Whisper.say("I need to know where we are first. " .. "Try looking around.")
			return
		end

		local ok, err = pcall(callback, room_id)

		if not ok then
			Whisper.say("My geographical records are being difficult.")
			blight.output("Qreeper geography error: " .. tostring(err))
		end
	end

	---The current room's map. Publishes first, so a room just walked into has one.
	local function current_map(room_id)
		publisher:publish()
		return memory:get_room_map(room_id)
	end

	---Give the current room's map these fields, splitting it off first when the room is still
	---part of the map it was entered from. The exit just used becomes `boundary`.
	---@param fields table `{ type, name, realm }`
	---@param boundary "door"|"portal"
	---@return table|nil map The updated map, nil when nothing was changed.
	local function claim_map(room_id, fields, boundary)
		local map = current_map(room_id)

		if not map then
			Whisper.say("This room is not on any map yet. Odd. Look around and try again.")
			return nil
		end

		local outside = tracker.previous_room
		local outside_map = outside and outside ~= room_id and memory:get_room_map(outside) or nil

		if outside_map and outside_map.id == map.id and map.entrance_id ~= room_id then
			if not tracker.arrived_by then
				Whisper.say("I didn't see how we got in here. Walk in through the door, then ask again.")
				return nil
			end

			local graph = memory:get_map()
			local inside = Placement.inside(graph, room_id, outside)

			if not inside then
				Whisper.say("This place connects back outside some other way, so there is no one door to split at.")
				return nil
			end

			-- The map's own first room never moves into a split-off part: if it is "inside",
			-- we are on the street side of the door.
			for _, id in ipairs(inside) do
				if id == map.entrance_id and id ~= room_id then
					pending_split = nil
					Whisper.say(
						"That would carry off #" .. id .. ", where " .. map.name .. " begins, so we are"
							.. " not inside anything. Run it in the first room past the door."
					)
					return nil
				end
			end

			-- A building is smaller than the town around it. Moving most of the map means we are
			-- standing on the street side of the exit, not inside.
			local in_map = 0

			for _, room in pairs(graph.rooms) do
				if room.map_id == map.id then
					in_map = in_map + 1
				end
			end

			local confirmed = pending_split
				and pending_split.room == room_id
				and pending_split.outside == outside
				and pending_split.count == #inside
				and os.time() - pending_split.at <= CONFIRM_SECONDS

			pending_split = nil

			if #inside > in_map - #inside and not confirmed then
				pending_split = { room = room_id, outside = outside, count = #inside, at = os.time() }
				Whisper.say(
					"That would carry off "
						.. #inside
						.. " of "
						.. in_map
						.. " rooms. If we really are inside, say it again. Otherwise run it in the first room past the door."
				)
				return nil
			end

			fields.boundary = boundary
			fields.name = fields.name or Placement.map_name(graph.rooms[room_id])
			memory:split_map(room_id, outside, inside, fields)
		elseif not outside_map and map.entrance_id ~= room_id then
			-- No way in seen (fresh login or reload): labelling now would rename the whole map
			-- around us, not the place we are standing in.
			Whisper.say("I didn't see how we got in here. Step out and back in, then ask again.")
			return nil
		else
			-- Already its own map (behind `enter`, or split before): just label it, and mark
			-- the way in so the outside room shows a door.
			if outside_map and outside_map.id ~= map.id then
				memory:set_boundary(outside, room_id, boundary)
			end

			memory:update_map(map.id, fields)
		end

		publisher:publish()

		return memory:get_room_map(room_id)
	end

	qreeper:add_alias("^qreeper:where$", function()
		in_room(function(room_id)
			publisher:publish()

			local room = memory:get_room(room_id)

			if not room then
				Whisper.say("We are in #" .. room_id .. ", which my records have never heard of.")
				return
			end

			blight.output(string.format("#%d %s", room.id, room.name))
			blight.output("  Level: " .. tostring(room.level or "?")
				.. (room.x and string.format("   cell %d,%d,%d", room.x, room.y, room.z or 0) or "   not placed"))

			if room.map_id then
				blight.output(string.format(
					"  Map:   #%d %s (%s, realm %s), entrance #%s%s",
					room.map_id,
					room.map_name,
					room.map_type,
					room.realm or "?",
					tostring(room.entrance_id),
					room.entrance_id == room.id and " (here)" or ""
				))
			else
				blight.output("  Map:   none yet")
			end

			local exits = {}

			for _, exit in ipairs(room.exits) do
				local text = exit.direction .. " " .. (exit.to and ("#" .. exit.to) or "?")

				if exit.map_id and exit.map_id ~= room.map_id then
					text = text .. " (" .. (exit.boundary or "into") .. " " .. exit.map_name .. ")"
				elseif exit.boundary then
					text = text .. " (" .. exit.boundary .. ")"
				end

				table.insert(exits, text)
			end

			blight.output("  Exits: " .. (#exits > 0 and table.concat(exits, ", ") or "none"))

			local previous = tracker.previous_room

			if previous and previous ~= room_id then
				blight.output("  From:  #" .. previous .. " by " .. tostring(tracker.arrived_by or "?"))
			end

			local notes = memory:get_notes(room_id)
			blight.output("  Notes: " .. #notes)
		end)
	end)

	qreeper:add_alias("^qreeper:level\\s+(-?\\d+)$", function(matches)
		local level = tonumber(matches[2])

		if level then
			in_room(function(room_id)
				memory:set_room_location(room_id, "level", level)
				publisher:publish()
				Whisper.say("Level " .. level .. ". Even I can count that high.")
			end)
		end
	end)

	qreeper:add_alias("^qreeper:realm\\s+(.+)$", function(matches)
		local realm = trim(matches[2])

		if realm == "" then
			return
		end

		in_room(function(room_id)
			local map = current_map(room_id)

			if not map then
				Whisper.say("This room is not on any map yet, so it has no realm to rename.")
				return
			end

			memory:update_map(map.id, { realm = realm })
			publisher:publish()
			Whisper.say("Very well. " .. map.name .. " lies in " .. realm .. ".")
		end)
	end)

	qreeper:add_alias("^qreeper:map-types?$", function()
		in_room(function(room_id)
			local map = current_map(room_id)

			if map then
				blight.output("Current map: " .. describe(map) .. ", entrance #" .. tostring(map.entrance_id))
			end

			blight.output("Map types: " .. table.concat(memory:get_map_types(), ", "))
		end)
	end)

	qreeper:add_alias("^qreeper:map-type-add\\s+(.+)$", function(matches)
		local name = trim(matches[2])

		if not name:match("^[%w][%w _%-]*$") then
			Whisper.say("A map type wants letters, digits, spaces or dashes. Not whatever that was.")
			return
		end

		local ok, added = pcall(function()
			return memory:add_map_type(name)
		end)

		if not ok then
			Whisper.say("The list of map types refuses to grow.")
			blight.output("Qreeper map-type-add error: " .. tostring(added))
		elseif added then
			Whisper.say(name:lower() .. " it is. I'll know one when I see one.")
		else
			Whisper.say("I already know about " .. name:lower() .. ".")
		end
	end)

	qreeper:add_alias("^qreeper:map-type\\s+(\\S+)\\s*(.*)$", function(matches)
		local requested = matches[2]
		local name = trim(matches[3])

		in_room(function(room_id)
			local map_type = memory:find_map_type(requested)

			if not map_type then
				Whisper.say(
					"I don't know a '"
						.. requested
						.. "'. Known: "
						.. table.concat(memory:get_map_types(), ", ")
						.. ". qreeper:map-type-add teaches me more."
				)
				return
			end

			local map = claim_map(room_id, { type = map_type, name = name ~= "" and name or nil }, "door")

			if map then
				Whisper.say("Noted: " .. map.name .. ", a " .. map.type .. ".")
			end
		end)
	end)

	qreeper:add_alias("^qreeper:portal\\s+(.+)$", function(matches)
		local realm = trim(matches[2])

		if realm == "" then
			return
		end

		in_room(function(room_id)
			if not tracker.previous_room or tracker.previous_room == room_id then
				Whisper.say("A portal from where? Step through it first.")
				return
			end

			local map = claim_map(room_id, { realm = realm }, "portal")

			if map then
				Whisper.say("Through the portal into " .. realm .. ". " .. map.name .. " starts here.")
			end
		end)
	end)

	qreeper:add_alias("^qreeper:map-merge$", function()
		in_room(function(room_id)
			local map = current_map(room_id)

			if not map then
				Whisper.say("This room is not on any map yet. Nothing to merge.")
				return
			end

			-- Only a compass link can carry the rooms back into a neighbour; behind a named exit
			-- they would just become a new map again.
			local graph = memory:get_map()
			local compass_link = false

			for _, exit in ipairs(graph.exits) do
				local from, to = graph.rooms[exit.from], exit.to and graph.rooms[exit.to]

				if Placement.OFFSETS[exit.direction] and from and to and from.map_id ~= to.map_id
					and (from.map_id == map.id or to.map_id == map.id) then
					compass_link = true
					break
				end
			end

			if not compass_link then
				Whisper.say(map.name .. " is only reached by named exits, so it stays a map of its own.")
				return
			end

			local moved = memory:merge_map(map.id)
			publisher:publish()
			Whisper.say(map.name .. " is folded back in. " .. moved .. " rooms rejoin the neighbourhood.")
		end)
	end)
end

return LocationAliases
