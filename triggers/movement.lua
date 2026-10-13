-- triggers/movement.lua
-- Failed-movement detection. A refused move must not stay queued, or the next room that
-- appears gets wired to the wrong direction.
--
-- Patterns are Blightmud regexes (see `/help regex`), not Lua patterns. They are compiled
-- with `regex.new(..., { case_insensitive = true })`, the documented way to ignore case.
-- TODO: these are generic MUD phrasings. Replace or extend them with the exact 3Scapes
-- messages once they have been seen in real output. Until then the advertised-exit check
-- and intent expiry in tracker.lua are the main safety net.

local MovementTriggers = {}

local FAILURE_PATTERNS = {
	"^\\s*(alas, )?you (can't|cannot|can not) go (that way|there)",
	"^\\s*there is no (exit|way) (in that direction|that way)",
	"^\\s*you (can't|cannot) (go|move) in that direction",
	"^\\s*(the|a) .+ (is|are) closed\\.?\\s*$",
	-- 3Scapes, Public Toilets: "A locked door blocks your passage to the east. You must
	-- insert the appropriate amount of coins to unlock it." (only the first line is matched)
	"^\\s*(a|an|the) .+ blocks? your (passage|way)",
}

---Register one trigger per failure pattern; each drops the oldest pending move.
---@param qreeper table Lifecycle instance that owns the triggers.
---@param tracker table
function MovementTriggers.register(qreeper, tracker)
	for _, pattern in ipairs(FAILURE_PATTERNS) do
		local compiled = regex.new(pattern, { case_insensitive = true })

		qreeper:add_trigger(compiled, { gag = false }, function()
			tracker:reject_move()
		end)
	end
end

return MovementTriggers
