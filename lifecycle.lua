-- lifecycle.lua
-- Owns everything one Qreeper instance registers, so a reload can undo it completely.
-- Always register aliases/triggers through these methods, never with alias.add/trigger.add directly.

local Lifecycle = {}
Lifecycle.__index = Lifecycle

---Create an empty lifecycle with no registrations and no database.
function Lifecycle.new()
	return setmetatable({
		aliases = {},
		triggers = {},
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

---Remove every owned trigger and alias, newest first, and close the database.
function Lifecycle:cleanup()
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

	self.triggers = {}
	self.aliases = {}
end

return Lifecycle
