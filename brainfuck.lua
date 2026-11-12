-- This is the actual interpreter lol

local M = {}
local outputCharacters = {}

for value = 0, 255 do
	outputCharacters[value + 1] = string.char(value)
end


local function compileProgram(source)
	local commands = {}
	local counts = {}
	local jumps = {}
	local openings = {}
	for sourcePosition = 1, #source do
		local command = source:byte(sourcePosition)
		if command == 60 or command == 62 or command == 43 or command == 45
			or command == 46 or command == 44 or command == 91 or command == 93 or command == 59 then
			local instruction = #commands
			if (command == 60 or command == 62 or command == 43 or command == 45)
				and commands[instruction] == command then
				counts[instruction] = counts[instruction] + 1
			elseif command == 60 or command == 62 or command == 43 or command == 45 then
				instruction = instruction + 1
				commands[instruction] = command
				counts[instruction] = 1
			else
				instruction = instruction + 1
				commands[instruction] = command
			end
			if command == 91 then
				openings[#openings + 1] = instruction
			elseif command == 93 then
				local opening = table.remove(openings)
				if not opening then
					io.stderr:write("error: unmatched ']' in program\n")
					os.exit(1)
				end
				jumps[opening] = instruction
				jumps[instruction] = opening
			end
		end
	end
	if #openings > 0 then
		io.stderr:write("error: unmatched '[' in program\n")
		os.exit(1)
	end
	return commands, jumps, counts
end

function M.buildJumpTable(source)
	local jumps = {}
	local openings = {}
	for bracket, after in source:gmatch("([%[%]])()") do
		local index = after - 2
		if bracket == "[" then
			openings[#openings + 1] = index
		else
			local opening = table.remove(openings)
			if not opening then
				io.stderr:write("error: unmatched ']' in program\n")
				os.exit(1)
			end
			jumps[opening] = index
			jumps[index] = opening
		end
	end
	if #openings > 0 then
		io.stderr:write("error: unmatched '[' in program\n")
		os.exit(1)
	end
	return jumps
end

function M.executeProgram(program, input, memsize, outputStream, options)
	local tape = {}
	local audio = options and options.audio and require("./audio")
	local audioHandle = audio and audio.open()
	local soundLength = options and options.soundLength or 0
	local audioStreaming = audio and program:find(";", 1, true) ~= nil
	local pointer = 0
	local inputPosition = 1
	local instruction = 1
	local output = {}
	local outputLength = 0
	local outputCount = 0
	local commands, jumps, counts = compileProgram(program)
	local outputUv = outputStream and require("uv")
	local audioSteps = 0
	if audio and not audioStreaming then
		audio.update(audioHandle.device, tape, 0, soundLength)
	end
	local function writeOutput(value)
		if outputStream then
			local written = false
			outputStream:write(value, function()
				written = true
			end)
			while not written do
				outputUv.run("once")
			end
		else
			io.write(value)
		end
	end
	local function flushOutput()
		if outputLength > 0 then
			writeOutput(table.concat(output, "", 1, outputCount))
			if not outputStream then
				io.flush()
			end
			output = {}
			outputLength = 0
			outputCount = 0
		end
	end
	while instruction <= #commands do
		audioSteps = audioSteps + 1
		if audio and not audioStreaming and audioSteps % 1024 == 0 then
			audio.update(audioHandle.device, tape, 0, soundLength)
		end
		local command = commands[instruction]
		if command == 62 then
			pointer = (pointer + counts[instruction]) % memsize
		elseif command == 60 then
			pointer = (pointer - counts[instruction]) % memsize
		elseif command == 43 then
			tape[pointer] = ((tape[pointer] or 0) + counts[instruction]) % 256
		elseif command == 45 then
			tape[pointer] = ((tape[pointer] or 0) - counts[instruction]) % 256
		elseif command == 46 then
			local value = tape[pointer] or 0
			outputLength = outputLength + 1
			outputCount = outputCount + 1
			output[outputCount] = outputCharacters[value + 1]
			if outputLength == 8192 then
				flushOutput()
			end
		elseif command == 44 then
			flushOutput()
			tape[pointer] = input:byte(inputPosition) or 0
			inputPosition = inputPosition + 1
		elseif command == 59 and audioStreaming then
			audio.enqueue(audioHandle.device, tape, 0, soundLength)
		elseif command == 91 then
			local value = tape[pointer] or 0
			if value == 0 then
				instruction = jumps[instruction]
			elseif value == 1 and commands[instruction + 1] == 62
				and commands[instruction + 2] == 43 and commands[instruction + 3] == 46
				and commands[instruction + 4] == 93 then
				local uniform = true
				for cell, cellValue in pairs(tape) do
					if cell ~= pointer and cellValue ~= 0 then
						uniform = false
						break
					end
				end
				if uniform then
					flushOutput()
					for currentValue = 1, 255 do
						local nextValue = (currentValue + 1) % 256
						local repeated = memsize - 1
						while repeated > 0 do
							local chunkLength = math.min(repeated, 8192 - outputLength)
							outputCount = outputCount + 1
							output[outputCount] = string.rep(outputCharacters[currentValue + 1], chunkLength)
							outputLength = outputLength + chunkLength
							repeated = repeated - chunkLength
							if outputLength == 8192 then
								flushOutput()
							end
						end
						outputCount = outputCount + 1
						outputLength = outputLength + 1
						output[outputCount] = outputCharacters[nextValue + 1]
						if outputLength == 8192 then
							flushOutput()
						end
					end
					tape = {}
					instruction = instruction + 4
				end
			end
		elseif command == 93 then
			if (tape[pointer] or 0) ~= 0 then
				instruction = jumps[instruction]
			end
		end
		instruction = instruction + 1
	end
	flushOutput()
	if audio then
		if audioStreaming then
			audio.drain(audioHandle.device)
		else
			audio.finish(audioHandle.device, tape, 0, soundLength)
		end
		audio.close(audioHandle)
	end
end

return M
