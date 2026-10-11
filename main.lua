local home = assert(os.getenv("HOME"))

local plugin_dir = home .. "/.local/share/blightmud/plugins/qreeper"

local db_path = home .. "/.local/share/blightmud/qreeper/worlds/3scapes.sqlite"

package.path = plugin_dir .. "/?.lua;" .. plugin_dir .. "/?/init.lua;" .. package.path

-- Remove the previous Qreeper instance.
if _G.Qreeper and _G.Qreeper.cleanup then
	_G.Qreeper:cleanup()
end

_G.Qreeper = nil

-- Refresh our Lua modules when developing.
-- Do not clear third-party modules such as lsqlite3.
for name in pairs(package.loaded) do
	if
		name == "memory"
		or name == "lifecycle"
		or name == "aliases"
		or name:match("^aliases%.")
		or name == "triggers"
		or name:match("^triggers%.")
	then
		package.loaded[name] = nil
	end
end

local Lifecycle = require("lifecycle")
local Memory = require("memory")
local Aliases = require("aliases")
local RoomTriggers = require("triggers.room")
local Whisper = require("whisper")
local Tracker = require("tracker")
local tracker = Tracker.new()
local MovementAliases = require("aliases.movement")

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

	Aliases.register(qreeper, memory)
	RoomTriggers.register(qreeper, memory, tracker)
	MovementAliases.register(qreeper, tracker)

	-- -- Reload without restarting Blightmud.
	-- qreeper:add_alias("^qreeper:reload$", function()
	-- 	dofile(plugin_dir .. "/main.lua")
	-- end)
end)

if not ok then
	qreeper:cleanup()
	_G.Qreeper = nil
	error(err)
end

Whisper.say("Ah, another awakening. " .. "I trust you have a reason.")
