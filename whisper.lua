local Whisper = {}

local RESET = "\27[0m"
local MUTED = "\27[2m"
local ITALIC = "\27[3m"

local MAX_MESSAGES = 1
local MAX_HISTORY = 1000
local history = {}

function Whisper.init()
	blight.status_height(math.max(3, MAX_MESSAGES + 1))
end

function Whisper.say(message)
	table.insert(history, message)

	if #history > MAX_HISTORY then
		table.remove(history, 1)
	end

	Whisper.render()
end

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

function Whisper.clear()
	history = {}
	Whisper.render()
end

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
