-- tests/identity_test.lua
-- identity.lua rules, plus remember_room/forget_room against a throwaway database.
-- Run from the plugin directory:
--   LUA_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so;;" lua5.4 tests/identity_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local Identity = require("identity")
local Memory = require("memory")

local failures = 0

---Assert equality and report the case name on failure.
local function expect(name, actual, expected)
	if actual ~= expected then
		failures = failures + 1
		print(string.format("FAIL %s: expected %s, got %s", name, tostring(expected), tostring(actual)))
	else
		print("ok   " .. name)
	end
end

-- Real Foundation Row openings: same name, same template, different rooms.
local ROW_A = "A small stone path leads through rows of storefronts and several buildings."
local ROW_B = "This small stone path leads both south and east along a row of storefronts."

expect("identical text is 1.0", Identity.similarity(ROW_A, ROW_A), 1)
expect("templated twins score low", Identity.similarity(ROW_A, ROW_B) < Identity.SIMILAR, true)
expect("empty text is no evidence", Identity.similarity("", ROW_A), nil)

local function choose(candidates, description, extra)
	local observation = { description = description }
	for key, value in pairs(extra or {}) do
		observation[key] = value
	end
	return Identity.choose(candidates, observation)
end

do
	local id, status = choose({}, ROW_A)
	expect("no candidates is new", status, "new")
	expect("no candidates has no id", id, nil)
end

do
	local id, status = choose({ { id = 95, description = ROW_A } }, ROW_A)
	expect("matching description is known", status, "known")
	expect("matching description picks it", id, 95)
end

do
	local _, status = choose({ { id = 95, description = ROW_A } }, ROW_B)
	expect("same fingerprint, other description is a twin", status, "twin")
end

do
	local candidates = { { id = 84, description = "Endless corridor." }, { id = 85, description = "Endless corridor." } }
	local _, status = choose(candidates, "Endless corridor.", { details = {} })
	expect("identical rooms without graph or details are ambiguous", status, "ambiguous")

	local id = choose(candidates, "Endless corridor.", { predicted_id = 85 })
	expect("graph evidence resolves identical rooms", id, 85)
end

do
	local id = choose({ { id = 95, description = ROW_A } }, ROW_B, { predicted_id = 95 })
	expect("graph evidence does not override a different description", id, nil)
end

do
	local id = choose({ { id = 95, description = ROW_A } }, "")
	expect("brief mode (no description) still matches", id, 95)
end

-- Hall of Champions: identical name, exits and description; one statue each.
local HALL = "This cavernous hall was built to honor the champions of the realms."
local SII = { "A statue of the great Sii, Seoman." }
local XAREE = { "A statue of the great Juggernaut, Xaree." }
local ZAL = { "A statue of the great Monk, Zal." }

do
	local halls = { { id = 107, description = HALL, details = SII } }
	local _, status = choose(halls, HALL, { from_id = 107 })
	expect("lookalike of the room just left waits for details", status, "need-details")

	local _, final = choose(halls, HALL, { from_id = 107, details = XAREE })
	expect("a move does not land where it started", final, "twin")

	local _, same_statue = choose(halls, HALL, { from_id = 107, details = SII })
	expect("same hall, same statue: the exit loops back", same_statue, "known")
end

do
	-- Valley of Eras: `nw` from a room shows the very same room, no details at all.
	local valley = "The trees above grow so densely that they shield out much of the sky.  The forest is peaceful and quiet."
	local id, status = choose({ { id = 194, description = valley } }, valley, { from_id = 194, details = {} })
	expect("identical room without details is a loop", id, 194)
	expect("loop is known", status, "known")
	local _, other = choose({ { id = 194, description = valley } }, valley .. " To the east the valley continues.", { from_id = 194, details = {} })
	expect("almost the same room we left is a twin", other, "twin")
end

do
	local halls = {
		{ id = 107, description = HALL, details = SII },
		{ id = 108, description = HALL, details = XAREE },
	}
	local _, status = choose(halls, HALL, { from_id = 108, details = ZAL })
	expect("new statue among known halls is a new hall", status, "twin")

	local id = choose(halls, HALL, { from_id = 999, details = { "A statue of the great Sii, Seoman.", "A rat is here." } })
	expect("statue picks the hall even with a rat about", id, 107)

	local back = choose(halls, HALL, { details = XAREE })
	expect("look in a hall is identified by its statue", back, 108)
end

do
	-- Ordinary single rooms never wait for details, monsters or not.
	local _, status = choose({ { id = 5, description = ROW_A, details = { "A rabbit is here." } } }, ROW_A, { from_id = 4 })
	expect("ordinary room does not need details", status, "known")
end

do
	expect("stable details keep what repeats", table.concat(Identity.stable_details({ "Statue.", "Rat." }, { "Statue.", "Wolf." }), "|"), "Statue.")
	expect("stable details survive a monster-only visit", table.concat(Identity.stable_details({ "Statue." }, { "Wolf." }), "|"), "Statue.")
end

-- Memory ------------------------------------------------------------------------------------

local path = os.tmpname()
os.remove(path)

do
	local memory = Memory.new(path)
	memory:initialize()

	local function observe(description, predicted)
		return memory:remember_room({
			name = "Foundation Row",
			exits = { "north", "south", "west" },
			fingerprint = "Foundation Row|north,south,west",
			description = description,
		}, { predicted_id = predicted })
	end

	local first, first_status = observe(ROW_A)
	local twin, twin_status = observe(ROW_B)
	local again, again_status = observe(ROW_A)

	expect("first sighting is new", first_status, "new")
	expect("different description becomes a twin", twin_status, "twin")
	expect("twin gets its own id", twin ~= first, true)
	expect("revisit finds the first room", again, first)
	expect("revisit is known", again_status, "known")

	memory:connect_rooms(first, "west", twin)
	memory:add_note(first, "keep me")

	local refused, reason, count = memory:forget_room(first)
	expect("room with notes is not forgotten", refused, false)
	expect("refusal says notes", reason, "notes")
	expect("refusal counts notes", count, 1)

	expect("room without notes is forgotten", memory:forget_room(twin), true)
	expect("arriving exit loses its destination", memory:get_room_exits(first).west, false)
	expect("missing room is reported", select(2, memory:forget_room(9999)), "missing")

	memory:close()
end

os.remove(path)

do
	-- Chaos Mountains: stock sentences make different rooms score 0.6+. A lookalike far from
	-- where the move lands needs a near-identical text; a true revisit (1.0) still matches.
	-- Two different rooms (#169 and #172 of the real walk), 0.66.
	local stored = "The Chaos Mountains The influence of the Chaos Flux is quite apparent here.  The mountains look far too treacherous to continue.  There is nothing here but rock and more rock -- and some stone.  To the south you almost miss an opening to a set of foothills, while to the southwest you determine that the range of mountains continues."
	local seen = "The Chaos Mountains Far beyond, you can see only more mountains.  The influence of the Chaos Flux is quite apparent here.  There is nothing here but rock and more rock -- and some stone.  To the southwest you barely sense an opening to a set of foothills, while to the west you just barely see that the range of mountains continues."
	local score = Identity.similarity(stored, seen)
	expect("stock sentences score between the thresholds", score >= Identity.SIMILAR and score < Identity.SIMILAR_STRICT, true)
	local _, near_status = choose({ { id = 171, description = stored } }, seen)
	expect("near lookalike still matches", near_status, "known")
	local _, far_status = choose({ { id = 171, description = stored, far = true } }, seen)
	expect("far lookalike is a twin", far_status, "twin")
	local id = choose({ { id = 171, description = stored, far = true } }, stored)
	expect("far but identical is a revisit", id, 171)
	local _, crowded_status = choose({ { id = 171, description = stored } }, seen, { crowded = true })
	expect("crowded lookalike is a twin", crowded_status, "twin")
	local predicted = choose({ { id = 171, description = stored } }, seen, { crowded = true, predicted_id = 171 })
	expect("crowded but predicted by the exit matches", predicted, 171)
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end

print("all identity tests passed")
