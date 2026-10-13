-- tests/help_test.lua
-- Every `qreeper:` alias appears in `qreeper:help`, and the help prints.
-- Run from the plugin directory:
--   LUA_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so;;" lua5.4 tests/help_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local printed = {}

blight = {
	output = function(text)
		table.insert(printed, text)
	end,
}

local Aliases = require("aliases")

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

-- Command names listed in the help: the first word of each entry.
local listed = {}

for _, group in ipairs(Aliases.HELP) do
	for _, entry in ipairs(group[2]) do
		listed[entry[1]:match("^(%S+)")] = true
	end
end

local files = {
	"aliases/init.lua",
	"aliases/whisper.lua",
	"aliases/movement.lua",
	"aliases/location.lua",
	"aliases/notes.lua",
	"aliases/map.lua",
	"aliases/rooms.lua",
	"aliases/journey.lua",
}

for _, path in ipairs(files) do
	local file = assert(io.open(path))
	local source = file:read("a")
	file:close()

	for pattern in source:gmatch('add_alias%("%^(qreeper[^"]*)"') do
		-- "qreeper:map-type\\s+..." -> "qreeper:map-type"; "qreeper:what\\??$" -> "qreeper:what"
		local command = pattern:match("^(qreeper[%w:%-]*)")
		command = command:gsub("%-$", "")

		expect(path .. " " .. command .. " is in help", listed[command] or false, true)
	end
end

Aliases.print_help()
expect("help has a title", printed[1], "Qreeper commands")
expect("help lists where", table.concat(printed, "\n"):find("qreeper:where", 1, true) ~= nil, true)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end

print("all help tests passed")
