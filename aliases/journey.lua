-- aliases/journey.lua
-- `qreeper:goto N` (or `#N`) starts a journey to room N; `qreeper:stay` ends it.
-- The journey itself (route finding and per-room whispers) lives in journey.lua.

local JourneyAliases = {}

---@param qreeper table Lifecycle instance that owns the aliases.
---@param journey table
function JourneyAliases.register(qreeper, journey)
	qreeper:add_alias("^qreeper:goto\\s+#?(\\d+)$", function(matches)
		local target = tonumber(matches[2])

		if target then
			journey:start(target)
		end
	end)

	qreeper:add_alias("^qreeper:stay$", function()
		journey:stop()
	end)
end

return JourneyAliases
