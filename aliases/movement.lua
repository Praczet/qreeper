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

function MovementAliases.register(qreeper, tracker)
	for _, direction in ipairs(directions) do
		local command = direction

		qreeper:add_alias("^" .. command .. "$", function()
			tracker:attempt_move(command)
			mud.send(command)
		end)
	end
	qreeper:add_alias("^qreeper:movement$", function()
		local direction = tracker.pending_direction or "none"

		Whisper.say("Pending movement: " .. direction)
	end)
end

return MovementAliases
