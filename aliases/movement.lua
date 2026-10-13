-- aliases/movement.lua
-- Movement and look aliases. They queue an intent in the tracker and pass the command on
-- unchanged; they never decide whether the move worked.

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

local look_commands = {
	"l",
	"look",
	"look around",
}

-- Named exits that are always tracked. Any other named exit the current room advertises
-- (`stables`, `gate`, ...) is tracked too, through a per-room alias (room_exit_pattern).
-- Each one is matched exactly (`^jump$`), so `jump down` passes through untracked.
local named_exits = {
	"enter",
	"out",
	"tutorial",
	"jump",
	"omp", -- enters a building
	"gswap",
	"wishroom",
	"exit",
	"gate", -- Woodland Road, out of Foundation into the forest
}

-- Words the fixed aliases above already handle.
local fixed = {}

for _, list in ipairs({ directions, named_exits }) do
	for _, command in ipairs(list) do
		fixed[command] = true
	end
end

---Alias pattern for the advertised exits that no fixed alias covers, or nil when none.
---Compass exits and up/down are always fixed; punctuation is escaped.
---@param exits string[] Advertised exits of the current room.
---@return string|nil
function MovementAliases.room_exit_pattern(exits)
	local words = {}
	local seen = {}

	for _, exit in ipairs(exits) do
		local word = exit:lower()

		if word ~= "" and not fixed[word] and not seen[word] then
			seen[word] = true
			table.insert(words, (word:gsub("%p", "\\%0")))
		end
	end

	if #words == 0 then
		return nil
	end

	table.sort(words)
	return "^(" .. table.concat(words, "|") .. ")$"
end

---Register movement, look and queue-inspection aliases.
---@param qreeper table Lifecycle instance that owns the aliases.
---@param tracker table
function MovementAliases.register(qreeper, tracker)
	for _, direction in ipairs(directions) do
		local command = direction

		qreeper:add_alias("^" .. command .. "$", function()
			tracker:attempt_move(command)
			mud.send(command)
		end)
	end

	for _, command in ipairs(named_exits) do
		local exit_command = command

		qreeper:add_alias("^" .. exit_command .. "$", function()
			tracker:attempt_move(exit_command)
			mud.send(exit_command)
		end)
	end

	-- Named exits of the room we stand in, re-registered on every room observation.
	local room_alias, room_pattern

	tracker:on_exits(function(exits)
		local pattern = MovementAliases.room_exit_pattern(exits)

		if pattern == room_pattern then
			return
		end

		if room_alias then
			qreeper:remove_alias(room_alias)
			room_alias = nil
		end

		room_pattern = pattern

		if pattern then
			room_alias = qreeper:add_alias(pattern, function(matches)
				local command = matches[2] or matches[1]
				tracker:attempt_move(command)
				mud.send(command)
			end).id
		end
	end)

	for _, command in ipairs(look_commands) do
		local input = command

		qreeper:add_alias("^" .. input .. "$", function()
			tracker:expect_look()
			mud.send(input)
		end)
	end

	-- Diagnostic: show what the tracker is still waiting for.
	qreeper:add_alias("^qreeper:movement$", function()
		Whisper.say("Pending: " .. tracker:describe_intents() .. ".")
	end)
end

return MovementAliases
