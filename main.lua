-- main.lua
-- Qreeper plugin entry point. Blightmud runs this on plugin load and on every reload.
--
-- Responsibilities: tear down the previous instance, refresh Qreeper's own modules, open the
-- world database, and register every alias and trigger through one Lifecycle so the next
-- reload can remove them again.

local home = assert(os.getenv("HOME"))

local plugin_dir = home .. "/.local/share/blightmud/plugins/qreeper"

local db_path = home .. "/.local/share/blightmud/qreeper/worlds/3scapes.sqlite"

package.path = plugin_dir .. "/?.lua;" .. plugin_dir .. "/?/init.lua;" .. package.path

-- Remove the previous Qreeper instance.
if _G.Qreeper and _G.Qreeper.cleanup then
	_G.Qreeper:cleanup()
end

_G.Qreeper = nil

-- Qreeper's own top-level modules. Anything under aliases/, triggers/ and map/ is matched
-- by prefix below. Third-party modules such as lsqlite3 are deliberately left loaded.
local OWNED_MODULES = {
	lifecycle = true,
	memory = true,
	observer = true,
	tracker = true,
	whisper = true,
	aliases = true,
	triggers = true,
	map = true,
}

---True when `name` is a module that belongs to this plugin and should be reloaded.
---@param name string
---@return boolean
local function is_owned_module(name)
	return OWNED_MODULES[name] or name:match("^aliases%.") or name:match("^triggers%.") or name:match("^map%.")
end

for name in pairs(package.loaded) do
	if is_owned_module(name) then
		package.loaded[name] = nil
	end
end

local Lifecycle = require("lifecycle")
local Memory = require("memory")
local Aliases = require("aliases")
local RoomTriggers = require("triggers.room")
local MovementTriggers = require("triggers.movement")
local Whisper = require("whisper")
local Tracker = require("tracker")
local MovementAliases = require("aliases.movement")
local LocationAliases = require("aliases.location")
local NoteAliases = require("aliases.notes")
local MapAliases = require("aliases.map")
local RoomsAliases = require("aliases.rooms")

local tracker = Tracker.new()

Whisper.init()

local qreeper = Lifecycle.new()
qreeper.tracker = tracker

-- Store the instance so a failed reload can also
-- be cleaned up during the next attempt.
_G.Qreeper = qreeper

local ok, err = pcall(function()
	local memory = Memory.new(db_path)
	qreeper.memory = memory

	memory:initialize()

	Aliases.register(qreeper)
	RoomTriggers.register(qreeper, memory, tracker)
	MovementTriggers.register(qreeper, tracker)
	MovementAliases.register(qreeper, tracker)
	LocationAliases.register(qreeper, memory, tracker)
	NoteAliases.register(qreeper, memory, tracker)
	MapAliases.register(qreeper, memory, tracker)
	RoomsAliases.register(qreeper, memory)
end)

if not ok then
	qreeper:cleanup()
	_G.Qreeper = nil
	error(err)
end

Whisper.say("Ah, another awakening. " .. "I trust you have a reason.")
