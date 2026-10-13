-- identity.lua
-- Decides which stored room an observation is. Pure Lua; memory.lua supplies the candidates.
--
-- Candidates are stored rooms with the same fingerprint (name + sorted exits). Evidence,
-- strongest first:
--   1. Graph: the exit just taken already leads to one of the candidates.
--   2. Description: word overlap with a candidate's stored description.
--   3. Details: the lines after "Obvious exits" (statues, items, monsters).
--   4. Movement: a confirmed move does not land in the room it started from - unless the
--      arrival is word for word the room we left and no detail line tells them apart: then
--      the exit loops back (Valley of Eras, 2026-10-13: `nw` from a room into itself).
--
-- Details and rule 4 are only consulted when name, exits and description cannot decide:
-- several stored rooms are alike, or the only lookalike is the room we just left. That is
-- the Hall of Champions case: identical halls told apart by one statue each. Ordinary rooms
-- never look at details, so a wandering monster cannot split a normal room in two.
--
-- Description threshold from the real world database (2026-10-12): distinct rooms mostly
-- score below 0.45, revisits of a static room score 1.0.
--
-- Strict matching (SIMILAR_STRICT) applies to a candidate the map places far from where the
-- move should land (`far`), and to every candidate when several stored rooms already share
-- the observed name (`crowded`) - unless the exit just taken already leads to it. The Chaos
-- Mountains and the Valley of Eras (2026-10-13) build every room from the same stock
-- sentences: two different rooms there scored up to 0.77, a revisit of one room still ~1.0.

local Identity = {}

-- Word-set overlap (Jaccard) at or above this means "the same description".
Identity.SIMILAR = 0.6
-- The same, under strict matching (far or crowded, see above).
Identity.SIMILAR_STRICT = 0.9

---Lowercased word set of a description.
---@param text string|nil
---@return table<string, boolean>, integer
local function words(text)
	local set, count = {}, 0

	for word in tostring(text or ""):lower():gmatch("[%w']+") do
		if not set[word] then
			set[word] = true
			count = count + 1
		end
	end

	return set, count
end

---Jaccard similarity of two descriptions, 0..1. Returns nil when either is empty: no evidence.
---@param a string|nil
---@param b string|nil
---@return number|nil
function Identity.similarity(a, b)
	local set_a, count_a = words(a)
	local set_b, count_b = words(b)

	if count_a == 0 or count_b == 0 then
		return nil
	end

	local shared = 0

	for word in pairs(set_a) do
		if set_b[word] then
			shared = shared + 1
		end
	end

	return shared / (count_a + count_b - shared)
end

---Normalised detail line, for comparing across visits.
---@param line string
---@return string
function Identity.detail_key(line)
	return (line:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

---True when two detail lists share at least one line.
---@param stored string[]
---@param observed string[]
---@return boolean
local function shares_detail(stored, observed)
	local keys = {}

	for _, line in ipairs(stored) do
		keys[Identity.detail_key(line)] = true
	end

	for _, line in ipairs(observed) do
		if keys[Identity.detail_key(line)] then
			return true
		end
	end

	return false
end

---Details that survive another visit: the lines seen both times. If nothing survives, the
---stored set is kept, because a visit where only monsters changed proves nothing.
---@param stored string[]
---@param observed string[]
---@return string[]
function Identity.stable_details(stored, observed)
	if #stored == 0 then
		return observed
	end

	if #observed == 0 then
		return stored
	end

	local seen = {}
	local kept = {}

	for _, line in ipairs(observed) do
		seen[Identity.detail_key(line)] = true
	end

	for _, line in ipairs(stored) do
		if seen[Identity.detail_key(line)] then
			table.insert(kept, line)
		end
	end

	if #kept == 0 then
		return stored
	end

	return kept
end

---True when a candidate's description does not contradict the observation.
---@param strict boolean Use SIMILAR_STRICT.
local function compatible(candidate, description, strict)
	local score = Identity.similarity(candidate.description, description)
	return score == nil or score >= (strict and Identity.SIMILAR_STRICT or Identity.SIMILAR)
end

---Pick the stored room for an observation.
---@param candidates table[] `{ id, description, details, far }` rooms with the observed
---fingerprint; `far` when the map puts the candidate away from where the move should land.
---@param observation table `{ description, details, predicted_id, from_id }`:
---  details       nil while the post-summary lines have not arrived yet
---  predicted_id  destination already recorded for the exit just taken
---  from_id       room a confirmed move started from (nil for look, teleports, unknowns)
---  crowded       several stored rooms share the observed name: strict matching
---@return integer|nil id Chosen room, or nil.
---@return "known"|"new"|"twin"|"ambiguous"|"need-details" status
---  twin          create a new room although stored rooms share its fingerprint
---  need-details  only the details can decide; ask again once they have arrived
function Identity.choose(candidates, observation)
	if #candidates == 0 then
		return nil, "new"
	end

	local similar = {}
	local from_is_similar = false

	for _, candidate in ipairs(candidates) do
		local predicted = candidate.id == observation.predicted_id
		local strict = not predicted and (candidate.far or observation.crowded)

		if compatible(candidate, observation.description, strict) then
			if candidate.id == observation.predicted_id then
				return candidate.id, "known"
			end

			if candidate.id == observation.from_id then
				from_is_similar = true
			end

			table.insert(similar, candidate)
		end
	end

	if #similar == 0 then
		return nil, "twin"
	end

	-- One clear match, and it is not the room we just walked out of: done.
	if #similar == 1 and not from_is_similar then
		return similar[1].id, "known"
	end

	if observation.details == nil then
		return nil, "need-details"
	end

	-- Rule 4: a confirmed move left `from_id`, so the arrival is somewhere else.
	local remaining = {}

	for _, candidate in ipairs(similar) do
		if candidate.id ~= observation.from_id then
			table.insert(remaining, candidate)
		end
	end

	if #remaining == 0 then
		-- Only the room we left looks like this. Identical text and nothing in the details to
		-- tell them apart: the exit loops back into it. (Halls of Champions differ by statue.)
		local from = similar[1]
		local score = Identity.similarity(from.description, observation.description)
		local stored = from.details or {}

		if score and score >= Identity.SIMILAR_STRICT
			and (#stored == 0 or #observation.details == 0 or shares_detail(stored, observation.details)) then
			return from.id, "known"
		end

		return nil, "twin"
	end

	if #observation.details > 0 then
		local matching = {}
		local all_have_details = true

		for _, candidate in ipairs(remaining) do
			local stored = candidate.details or {}

			if #stored == 0 then
				all_have_details = false
			elseif shares_detail(stored, observation.details) then
				table.insert(matching, candidate)
			end
		end

		if #matching == 1 then
			return matching[1].id, "known"
		end

		-- Every lookalike has recorded details and none of them is here: a new lookalike.
		if #matching == 0 and all_have_details then
			return nil, "twin"
		end
	end

	-- Identical rooms and nothing (no graph, no details) to tell them apart: don't guess.
	return nil, "ambiguous"
end

return Identity
