-- aliases/whisper.lua
-- `qreeper:what` / `qreeper:what?`: replay recent whispers in scrollback.

local Whisper = require("whisper")
local WhisperAliases = {}

---@param qreeper table Lifecycle instance that owns the alias.
function WhisperAliases.register(qreeper)
	qreeper:add_alias("^qreeper:what\\??$", function()
		Whisper.recall()
	end)
end

return WhisperAliases
