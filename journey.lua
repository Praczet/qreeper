-- journey.lua
-- An active `qreeper:goto` journey: a destination and what to tell the player on each arrival.
--
-- The journey keeps only the destination, not a fixed route. Every confirmed arrival
-- recalculates from where the player actually is, so detours, failed moves and being dragged
-- elsewhere all give correct directions without special cases. Qreeper never sends the
-- moves itself; it only whispers them.
--
-- Routes may include probable steps (marked `?`): the untested way back along an exit you
-- just walked, when the room lists it. See navigator.lua.
--
-- A journey ends when the destination is reached or on `qreeper:stay`. Losing the position
-- pauses it; the next recognised room resumes it.

local Whisper = require("whisper")
local Navigator = require("navigator")

local Journey = {}
Journey.__index = Journey

---Create an idle journey.
---@param memory table
---@param tracker table
function Journey.new(memory, tracker)
	return setmetatable({
		memory = memory,
		tracker = tracker,
		target = nil,
	}, Journey)
end

---True while a destination is set.
---@return boolean
function Journey:active()
	return self.target ~= nil
end

---Route from the current room to the target, or nil plus a reason.
---@return table[]|nil steps
---@return string|nil reason `"lost"` or `"no-route"`.
function Journey:plan()
	local current = self.tracker.current_room

	if not current then
		return nil, "lost"
	end

	local steps = Navigator.route(self.memory:get_map(), current, self.target)

	if not steps then
		return nil, "no-route"
	end

	return steps
end

---Print the full route with room ids to scrollback, for when the whisper line is too short.
---@param steps table[]
local function print_route(memory, target, steps)
	local graph = memory:get_map()
	local parts = {}

	for _, step in ipairs(steps) do
		table.insert(parts, Navigator.command(step.direction) .. (step.probable and "?" or "") .. " → #" .. step.to)
	end

	blight.output("Qreeper route to #" .. target .. " (" .. graph.rooms[target].name .. "), " .. #steps .. " moves:")
	blight.output("  " .. table.concat(parts, ", "))

	if Navigator.has_probable(steps) then
		blight.output("  ? = never walked that way; the room lists the exit back, so it is probably right.")
	end
end

---Start a journey to `target_id`.
---@param target_id integer
function Journey:start(target_id)
	local graph = self.memory:get_map()

	if not graph.rooms[target_id] then
		Whisper.say("Room #" .. target_id .. "? I have no such memory. I would remember. Probably.")
		return
	end

	if self.tracker.current_room == target_id then
		self.target = nil
		Whisper.say("We are already in #" .. target_id .. ". That was a short journey.")
		return
	end

	self.target = target_id

	local steps, reason = self:plan()

	if reason == "lost" then
		Whisper.say("To #" .. target_id .. ", yes. Once I know where we are. Look around.")
		return
	end

	if reason == "no-route" then
		Whisper.say("I know #" .. target_id .. ", but not a walked path there from here. I'll keep listening.")
		return
	end

	print_route(self.memory, target_id, steps)
	Whisper.say("The journey begins. To #" .. target_id .. ": " .. Navigator.describe(steps) .. ".")
end

---End the journey without arriving.
function Journey:stop()
	if not self.target then
		Whisper.say("We weren't going anywhere. Staying comes naturally.")
		return
	end

	local target = self.target
	self.target = nil
	Whisper.say("Very well, we stay. #" .. target .. " will wait.")
end

---Called after every finished room observation. Re-plans and whispers the next steps.
function Journey:on_arrival()
	if not self.target then
		return
	end

	if self.tracker.current_room == self.target then
		local target = self.target
		self.target = nil
		Whisper.say("We have arrived at #" .. target .. ". Try to look surprised.")
		return
	end

	local steps, reason = self:plan()

	if reason == "lost" then
		Whisper.say("I've lost our bearings. The journey to #" .. self.target .. " resumes when I recognise something.")
		return
	end

	if reason == "no-route" then
		Whisper.say("From here I know no walked path to #" .. self.target .. ". Find one, and I'll take the credit.")
		return
	end

	if #steps == 1 then
		Whisper.say("To #" .. self.target .. ": just " .. Navigator.describe(steps) .. ".")
		return
	end

	Whisper.say("To #" .. self.target .. " you should follow " .. Navigator.describe(steps) .. ".")
end

return Journey
