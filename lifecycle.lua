local Lifecycle = {}
Lifecycle.__index = Lifecycle

function Lifecycle.new()
	return setmetatable({
		aliases = {},
		triggers = {},
		memory = nil,
	}, Lifecycle)
end

function Lifecycle:add_alias(pattern, callback)
	local item = alias.add(pattern, callback)

	assert(item and item.id, "Could not register alias")

	table.insert(self.aliases, item.id)
	return item
end

function Lifecycle:add_trigger(pattern, options, callback)
	local item = trigger.add(pattern, options, callback)

	assert(item and item.id, "Could not register trigger")

	table.insert(self.triggers, item.id)
	return item
end

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
