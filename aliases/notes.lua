-- aliases/notes.lua
-- Room notes: `qreeper:note TEXT`, `qreeper:notes`, `qreeper:notes-for-room ID`,
-- `qreeper:notes-by-room`, `qreeper:forget-note ID`. Notes attach to room ids, never names.
-- Marks: `qreeper:mark-it [TEXT]` marks the current room (drawn apart on the QREEP map) and
-- adds TEXT as a note; `qreeper:unmark-it` removes the mark, the notes stay.

local Whisper = require("whisper")

local NoteAliases = {}

---Current room id, or nil after whispering that we are lost.
local function current_room(tracker)
	local id = tracker.current_room

	if not id then
		Whisper.say("Where exactly are we? Look around first, " .. "then we can discuss your observations.")
		return nil
	end

	return id
end

---Strip leading and trailing whitespace.
local function trim(text)
	return text:match("^%s*(.-)%s*$")
end

---Print all notes for one room to scrollback.
local function display_notes(memory, room_id)
	local ok, notes = pcall(function()
		return memory:get_notes(room_id)
	end)

	if not ok then
		Whisper.say("My notebook refuses to cooperate.")
		return
	end

	if #notes == 0 then
		Whisper.say("No notes for room #" .. room_id .. ".")
		return
	end

	blight.output("Qreeper's notebook — room #" .. room_id)

	for _, note in ipairs(notes) do
		blight.output("  #" .. note.id .. "  " .. note.content)
	end

	Whisper.say(#notes .. " entries for room #" .. room_id .. ". Remarkably organized, aren't we?")
end

---@param qreeper table Lifecycle instance that owns the aliases.
---@param memory table
---@param tracker table
---@param publisher table Snapshot publisher; notes appear on the QREEP map.
function NoteAliases.register(qreeper, memory, tracker, publisher)
	-- Add a note.
	qreeper:add_alias("^qreeper:note\\s+(.+)$", function(matches)
		local room_id = current_room(tracker)
		if not room_id then
			return
		end

		local content = trim(matches[2])
		if content == "" then
			return
		end

		local ok, id = pcall(function()
			return memory:add_note(room_id, content)
		end)

		if not ok then
			Whisper.say("I seem to have misplaced my notebook.")
			return
		end

		publisher:publish()
		Whisper.say("Entry " .. id .. ". Preserved for posterity. Or until you change your mind.")
	end)

	-- Mark the current room, optionally with a note. Marking twice is harmless.
	qreeper:add_alias("^qreeper:mark-it(?:\\s+(.*))?$", function(matches)
		local room_id = current_room(tracker)
		if not room_id then
			return
		end

		local content = trim(matches[2] or "")

		local ok, note_id = pcall(function()
			return memory:transaction(function()
				memory:set_marked(room_id, true)

				if content ~= "" then
					return memory:add_note(room_id, content)
				end
			end)
		end)

		if not ok then
			Whisper.say("The mark would not stick. Nothing changed.")
			blight.output("Qreeper mark-it error: " .. tostring(note_id))
			return
		end

		publisher:publish()

		if note_id then
			Whisper.say("#" .. room_id .. " marked, with entry " .. note_id .. ". X marks the spot, finally literally.")
		else
			Whisper.say("#" .. room_id .. " marked. I'll make it stand out, like you in a crowd of goblins.")
		end
	end)

	qreeper:add_alias("^qreeper:unmark-it$", function()
		local room_id = current_room(tracker)
		if not room_id then
			return
		end

		local ok, err = pcall(function()
			memory:set_marked(room_id, false)
		end)

		if not ok then
			Whisper.say("The mark clings on. Nothing changed.")
			blight.output("Qreeper unmark-it error: " .. tostring(err))
			return
		end

		publisher:publish()
		Whisper.say("#" .. room_id .. " is ordinary again. Its notes stay.")
	end)

	qreeper:add_alias("^qreeper:notes-by-room$", function()
		local ok, rooms = pcall(function()
			return memory:get_rooms_with_notes()
		end)

		if not ok then
			Whisper.say("My index seems to have misplaced itself.")
			return
		end

		if #rooms == 0 then
			Whisper.say("An empty notebook. Such wasted potential.")
			return
		end

		blight.output("Qreeper's notebook — rooms with notes")
		blight.output("")

		for _, room in ipairs(rooms) do
			local location = {}

			if room.realm then
				table.insert(location, room.realm)
			end

			if room.map_name then
				table.insert(location, room.map_name)
			end

			local suffix = ""

			if #location > 0 then
				suffix = " [" .. table.concat(location, " / ") .. "]"
			end

			blight.output(string.format("  #%d  %s%s  (%d notes)", room.id, room.name, suffix, room.note_count))
		end

		Whisper.say(#rooms .. " rooms contain notes. " .. "I do occasionally pay attention.")
	end)

	qreeper:add_alias("^qreeper:notes$", function()
		local room_id = current_room(tracker)

		if room_id then
			display_notes(memory, room_id)
		end
	end)

	qreeper:add_alias("^qreeper:notes-for-room\\s+(\\d+)$", function(matches)
		local room_id = tonumber(matches[2])

		if not room_id then
			return
		end

		display_notes(memory, room_id)
	end)
	-- Delete a note from the current room.
	qreeper:add_alias("^qreeper:forget-note\\s+(\\d+)$", function(matches)
		local room_id = current_room(tracker)
		if not room_id then
			return
		end

		local note_id = tonumber(matches[2])

		local ok, deleted = pcall(function()
			return memory:delete_note(room_id, note_id)
		end)

		if not ok then
			Whisper.say("Even forgetting appears to require effort.")
			return
		end

		if deleted then
			publisher:publish()
			Whisper.say("Entry " .. note_id .. " has vanished. I shall deny it ever existed.")
		else
			Whisper.say("No such entry belongs to this place.")
		end
	end)
end

return NoteAliases
