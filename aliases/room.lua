local Whisper = require("whisper")
local RoomAliases = {}

function RoomAliases.register(qreeper, memory)
	qreeper:add_alias("^qreeper:test_room$", function()
		local name = "Newbie tower courtyard"

		local ok, result = pcall(function()
			return memory:add_room({
				fingerprint = "test-courtyard",
				name = name,
				realm = "material",
				area = "Newbieland",
				level = 0,
				x = 0,
				y = 0,
			})
		end)

		if not ok then
			Whisper.say("My memory failed me. " .. tostring(result))
			return
		end

		Whisper.say(name .. ". Another memory acquired. (#" .. result .. ")")
	end)
end

return RoomAliases
