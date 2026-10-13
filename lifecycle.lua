-- lifecycle.lua
-- Owns everything one Qreeper instance registers, so a reload can undo it completely.
-- Always register aliases, triggers and timers through these methods, never with
-- alias.add/trigger.add/timer.add directly.

local Lifecycle = {}
Lifecycle.__index = Lifecycle

---Create an empty lifecycle with no registrations and no database.
function Lifecycle.new()
	return setmetatable({
		aliases = {},
		triggers = {},
		timers = {},
		memory = nil,
	}, Lifecycle)
end

---Register an alias and remember its id for cleanup.
---@param pattern string Blightmud alias regex.
---@param callback function
function Lifecycle:add_alias(pattern, callback)
	local item = alias.add(pattern, callback)

	assert(item and item.id, "Could not register alias")

	table.insert(self.aliases, item.id)
	return item
end

---Remove an alias registered with add_alias before cleanup.
---@param id integer
function Lifecycle:remove_alias(id)
	for i = #self.aliases, 1, -1 do
		if self.aliases[i] == id then
			table.remove(self.aliases, i)
			alias.remove(id)
			return
		end
	end
end

---Register a trigger and remember its id for cleanup.
---@param pattern string|userdata Blightmud regex string or `regex.new` object.
---@param options table Trigger options (gag, prompt, ...).
---@param callback function
function Lifecycle:add_trigger(pattern, options, callback)
	local item = trigger.add(pattern, options, callback)

	assert(item and item.id, "Could not register trigger")

	table.insert(self.triggers, item.id)
	return item
end

---Start a repeating timer and remember its id for cleanup.
---@param seconds number Interval between calls.
---@param callback function
function Lifecycle:add_timer(seconds, callback)
	-- `/help timers`: repeat count 0 runs forever; the return value is the timer id.
	local item = timer.add(seconds, 0, callback)
	local id = type(item) == "table" and item.id or item

	assert(id, "Could not register timer")

	table.insert(self.timers, id)
	return id
end

---Remove every owned timer, trigger and alias, newest first, and close the database.
function Lifecycle:cleanup()
	-- Remove timers
	for i = #self.timers, 1, -1 do
		timer.remove(self.timers[i])
	end

	-- Remove triggers
	for i = #self.triggers, 1, -1 do
		trigger.remove(self.triggers[i])
	end

	-- Remove aliases
	for i = #self.aliases, 1, -1 do
		alias.remove(self.aliases[i])
	end

	-- Close the database
	if self.memory then
		self.memory:close()
		self.memory = nil
	end

	self.timers = {}
	self.triggers = {}
	self.aliases = {}
end

return Lifecycle
