local Whisper = require("whisper")

local Aliases = {}

function Aliases.register(qreeper, memory)
	qreeper:add_alias("^qreeper$", function()
		Whisper.say("Still here. " .. "Did you expect me to leave?")
	end)

	require("aliases.room").register(qreeper, memory)
	require("aliases.whisper").register(qreeper)
end

return Aliases
