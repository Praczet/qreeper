-- aliases/init.lua
-- General Qreeper aliases that need neither the database nor the tracker.
-- Feature aliases (movement, notes, map, rooms, location) register themselves from main.lua.

local Whisper = require("whisper")

local Aliases = {}

-- `qreeper:help`, grouped. Keep in step with the aliases and the README command table;
-- tests/help_test.lua checks that every qreeper: alias is listed here.
Aliases.HELP = {
	{
		"Where am I",
		{
			{ "qreeper:where", "room number, name, level, map, realm, exits, notes" },
			{ "qreeper:map", "ASCII map of the current level" },
			{ "qreeper:rooms [realm|map|level [VALUE]]", "room catalogue, grouped or filtered" },
			{ "qreeper:movement", "moves and looks still waiting for a room" },
			{ "qreeper:what", "replay recent whispers" },
		},
	},
	{
		"Maps and places",
		{
			{ "qreeper:map-type TYPE [NAME]", "in the first room inside: label or split off this map (repeat to confirm a big split)" },
			{ "qreeper:map-types", "current map and known types" },
			{ "qreeper:map-type-add NAME", "teach a new map type (sewer, tower, ...)" },
			{ "qreeper:portal REALM", "just after a realm gate: the exit was a portal into REALM" },
			{ "qreeper:realm NAME", "set the current map's realm" },
			{ "qreeper:level N", "set the current room's level" },
			{ "qreeper:map-merge", "undo a split, rejoin the neighbouring map" },
			{ "qreeper:relayout", "lay out the current map again" },
		},
	},
	{
		"Travel",
		{
			{ "qreeper:goto N", "route to room N, whispered step by step" },
			{ "qreeper:stay", "end the journey" },
		},
	},
	{
		"Notes",
		{
			{ "qreeper:note TEXT", "add a note to this room" },
			{ "qreeper:notes", "latest notes" },
			{ "qreeper:notes-for-room ID", "notes of one room" },
			{ "qreeper:notes-by-room", "rooms that have notes" },
			{ "qreeper:forget-note ID", "delete a note from this room" },
		},
	},
	{
		"Repairs",
		{
			{ "qreeper:check", "rooms that look merged by mistake" },
			{ "qreeper:forget-room N", "delete a misidentified room" },
		},
	},
	{
		"Other",
		{
			{ "qreeper", "is it still there?" },
			{ "qreeper:help", "this list" },
		},
	},
}

---Print Aliases.HELP to scrollback, commands aligned.
function Aliases.print_help()
	local width = 0

	for _, group in ipairs(Aliases.HELP) do
		for _, entry in ipairs(group[2]) do
			width = math.max(width, #entry[1])
		end
	end

	blight.output("Qreeper commands")

	for _, group in ipairs(Aliases.HELP) do
		blight.output("")
		blight.output(group[1])

		for _, entry in ipairs(group[2]) do
			blight.output(string.format("  %-" .. width .. "s  %s", entry[1], entry[2]))
		end
	end

	blight.output("")
	blight.output("Moves tracked: compass, u/d, " .. "enter, out, gate and the other named exits; l/look.")
end

---Register the `qreeper` ping, `qreeper:help` and the whisper-history alias.
---@param qreeper table Lifecycle instance that owns the aliases.
function Aliases.register(qreeper)
	qreeper:add_alias("^qreeper$", function()
		Whisper.say("Still here. " .. "Did you expect me to leave?")
	end)

	qreeper:add_alias("^qreeper:help$", function()
		Aliases.print_help()
	end)

	require("aliases.whisper").register(qreeper)
end

return Aliases
