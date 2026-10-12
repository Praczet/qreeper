-- whisper.lua
-- Qreeper's voice: short in-character messages on Blightmud's status line, with a history
-- that `qreeper:what` replays into scrollback. Diagnostics belong in blight.output, not here.

local Whisper = {}

local RESET = "\27[0m"
local MUTED = "\27[2m"
local ITALIC = "\27[3m"

-- Status lines shown at once, and how many past messages `qreeper:what` can recall.
local MAX_MESSAGES = 1
local MAX_HISTORY = 1000
local history = {}

---Reserve status-bar space for the whisper line.
function Whisper.init()
	blight.status_height(math.max(3, MAX_MESSAGES + 1))
end

---Whisper a message and keep it in history.
---@param message string
function Whisper.say(message)
	table.insert(history, message)

	if #history > MAX_HISTORY then
		table.remove(history, 1)
	end

	Whisper.render()
end

---Redraw the status line(s) from the newest messages.
function Whisper.render()
	for i = 1, MAX_MESSAGES do
		local message = history[#history - MAX_MESSAGES + i]

		local text = ""

		if message then
			text = MUTED .. ITALIC .. "Qreeper whispers: " .. message .. RESET
		end

		blight.status_line(i, text)
	end
end

---Forget history and blank the status line.
function Whisper.clear()
	history = {}
	Whisper.render()
end

---Print the whisper history to scrollback.
function Whisper.recall()
	blight.output(
		"Qreeper whispers: You could simply pay attention "
			.. "the first time. But apparently that's my responsibility too."
	)

	if #history == 0 then
		blight.output("Qreeper whispers: I've said nothing worth remembering.")
		return
	end

	for _, message in ipairs(history) do
		blight.output("  " .. message)
	end
end

return Whisper
