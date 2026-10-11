local Whisper = require("whisper")
local WhisperAliases = {}

function WhisperAliases.register(qreeper)
	qreeper:add_alias("^qreeper:what\\??$", function()
		Whisper.recall()
	end)
end

return WhisperAliases
