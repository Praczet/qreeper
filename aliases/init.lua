-- aliases/init.lua
-- General Qreeper aliases that need neither the database nor the tracker.
-- Feature aliases (movement, notes, map, rooms, location) register themselves from main.lua.

local Whisper = require("whisper")

local Aliases = {}

---Register the `qreeper` ping and the whisper-history alias.
---@param qreeper table Lifecycle instance that owns the aliases.
function Aliases.register(qreeper)
	qreeper:add_alias("^qreeper$", function()
		Whisper.say("Still here. " .. "Did you expect me to leave?")
	end)

	require("aliases.whisper").register(qreeper)
end

return Aliases
