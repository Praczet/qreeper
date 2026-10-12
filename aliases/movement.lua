-- aliases/movement.lua
-- Movement and look aliases. They queue an intent in the tracker and pass the command on
-- unchanged; they never decide whether the move worked.

local Whisper = require("whisper")
local MovementAliases = {}

local directions = {
	"n",
	"s",
	"e",
	"w",
	"u",
	"d",
	"ne",
	"nw",
	"se",
	"sw",
	"north",
	"south",
	"east",
	"west",
	"up",
	"down",
	"northeast",
	"northwest",
	"southeast",
	"southwest",
}

local look_commands = {
	"l",
	"look",
	"look around",
}

-- Named exits seen in 3Scapes so far. Add more when they show up.
local named_exits = {
	"enter",
	"out",
	"tutorial",
}

---Register movement, look and queue-inspection aliases.
---@param qreeper table Lifecycle instance that owns the aliases.
---@param tracker table
function MovementAliases.register(qreeper, tracker)
	for _, direction in ipairs(directions) do
		local command = direction

		qreeper:add_alias("^" .. command .. "$", function()
			tracker:attempt_move(command)
			mud.send(command)
		end)
	end

	for _, command in ipairs(named_exits) do
		local exit_command = command

		qreeper:add_alias("^" .. exit_command .. "$", function()
			tracker:attempt_move(exit_command)
			mud.send(exit_command)
		end)
	end

	for _, command in ipairs(look_commands) do
		local input = command

		qreeper:add_alias("^" .. input .. "$", function()
			tracker:expect_look()
			mud.send(input)
		end)
	end

	-- Diagnostic: show what the tracker is still waiting for.
	qreeper:add_alias("^qreeper:movement$", function()
		Whisper.say("Pending: " .. tracker:describe_intents() .. ".")
	end)
end

return MovementAliases
