-- This is probably the biggest part of brainmelt simply because of the copious amounts of optimizations I tried to add here

local readAll = require("./file").readAll

local M = {}

local function compileDisplayProgram(source)
	local commands = source:gsub("[^<>+%-%.,%[%]*;]", "")
	local depth = 0
	for position = 1, #commands do
		local command = commands:sub(position, position)
		if command == "[" then
			depth = depth + 1
		elseif command == "]" then
			depth = depth - 1
			if depth < 0 then
				io.stderr:write("error: unmatched ']' in program\n")
				os.exit(1)
			end
		end
	end
	if depth > 0 then
		io.stderr:write("error: unmatched '[' in program\n")
		os.exit(1)
	end
	return commands
end

local function initializeDisplay(options)
	local ffi = require("ffi")
	ffi.cdef[[
		typedef unsigned char Uint8;
		typedef unsigned int Uint32;
		typedef unsigned long long Uint64;
		typedef struct SDL_Window SDL_Window;
		typedef struct SDL_Renderer SDL_Renderer;
		typedef struct SDL_Texture SDL_Texture;
		typedef struct SDL_mutex SDL_mutex;
		typedef struct SDL_Rect { int x, y, w, h; } SDL_Rect;
		typedef union SDL_Event { Uint32 type; Uint8 padding[56]; } SDL_Event;
		int SDL_Init(Uint32 flags);
		void SDL_Quit(void);
		const char *SDL_GetError(void);
		SDL_Window *SDL_CreateWindow(const char *title, int x, int y, int w, int h, Uint32 flags);
		void SDL_DestroyWindow(SDL_Window *window);
		SDL_Renderer *SDL_CreateRenderer(SDL_Window *window, int index, Uint32 flags);
		void SDL_DestroyRenderer(SDL_Renderer *renderer);
		SDL_Texture *SDL_CreateTexture(SDL_Renderer *renderer, Uint32 format, int access, int w, int h);
		void SDL_DestroyTexture(SDL_Texture *texture);
		int SDL_UpdateTexture(SDL_Texture *texture, const SDL_Rect *rect, const void *pixels, int pitch);
		int SDL_RenderClear(SDL_Renderer *renderer);
		int SDL_RenderCopy(SDL_Renderer *renderer, SDL_Texture *texture, const SDL_Rect *src, const SDL_Rect *dst);
		void SDL_RenderPresent(SDL_Renderer *renderer);
		int SDL_PollEvent(SDL_Event *event);
		void SDL_Delay(Uint32 ms);
		Uint64 SDL_GetTicks64(void);
		SDL_mutex *SDL_CreateMutex(void);
		int SDL_LockMutex(SDL_mutex *mutex);
		int SDL_UnlockMutex(SDL_mutex *mutex);
		void SDL_DestroyMutex(SDL_mutex *mutex);
	]]
	local loaded, sdl = pcall(ffi.load, "libSDL2-2.0.so.0")
	if not loaded then
		io.stderr:write("error: cannot load SDL2: " .. tostring(sdl) .. "\n")
		os.exit(1)
	end

	local palette = ""
	if options.color == "p" then
		local scriptDirectory = process.argv[1]:match("^(.*[/\\])") or ""
		palette = readAll(scriptDirectory .. "palette.bin", "palette")
		if #palette < 768 then
			io.stderr:write("error: palette.bin must contain 256 RGB colors (768 bytes)\n")
			os.exit(1)
		end
	end

	if sdl.SDL_Init(32) ~= 0 then
		io.stderr:write("error: SDL initialization failed: " .. ffi.string(sdl.SDL_GetError()) .. "\n")
		os.exit(1)
	end
	local window = sdl.SDL_CreateWindow("Brainfuck memory", 0x2FFF0000, 0x2FFF0000,
		options.width * options.size, options.height * options.size, 4)
	if window == nil then
		io.stderr:write("error: cannot create display window: " .. ffi.string(sdl.SDL_GetError()) .. "\n")
		sdl.SDL_Quit()
		os.exit(1)
	end
	local renderer = sdl.SDL_CreateRenderer(window, -1, 0)
	if renderer == nil then
		io.stderr:write("error: cannot create display renderer: " .. ffi.string(sdl.SDL_GetError()) .. "\n")
		sdl.SDL_DestroyWindow(window)
		sdl.SDL_Quit()
		os.exit(1)
	end
	local texture = sdl.SDL_CreateTexture(renderer, 0x17101803, 1, options.width, options.height)
	if texture == nil then
		io.stderr:write("error: cannot create display texture: " .. ffi.string(sdl.SDL_GetError()) .. "\n")
		sdl.SDL_DestroyRenderer(renderer)
		sdl.SDL_DestroyWindow(window)
		sdl.SDL_Quit()
		os.exit(1)
	end
	local mutex = sdl.SDL_CreateMutex()
	if mutex == nil then
		io.stderr:write("error: cannot create display mutex: " .. ffi.string(sdl.SDL_GetError()) .. "\n")
		sdl.SDL_DestroyTexture(texture)
		sdl.SDL_DestroyRenderer(renderer)
		sdl.SDL_DestroyWindow(window)
		sdl.SDL_Quit()
		os.exit(1)
	end

	return {
		ffi = ffi,
		sdl = sdl,
		palette = palette,
		window = window,
		renderer = renderer,
		texture = texture,
		mutex = mutex,
		frameInterval = 1000 / options.maxfps,
		lastFrame = sdl.SDL_GetTicks64() - 1000 / options.maxfps,
		open = true,
	}
end

function M.runDisplay(options, program, input)
	program = compileDisplayProgram(program)
	local display = initializeDisplay(options)
	local ffi = display.ffi
	local uv = require("uv")
	local frameStride = options.color == "r" and 3 or 1
	local frameBytes = options.width * options.height * frameStride
	local frameCapacity = 8
	local queueHeaderBytes = 16
	local queueMemory = ffi.new("Uint8[?]", queueHeaderBytes + frameBytes * frameCapacity)
	local programMemory = ffi.new("Uint8[?]", #program + 1)
	ffi.copy(programMemory, program, #program)
	local queue = ffi.cast("Uint32 *", queueMemory)
	local queueData = ffi.cast("Uint8 *", queueMemory) + queueHeaderBytes
	local queueAddress = tonumber(ffi.cast("uint64_t", ffi.cast("void *", queueMemory)))
	local mutexAddress = tonumber(ffi.cast("uint64_t", ffi.cast("void *", display.mutex)))
	local programAddress = tonumber(ffi.cast("uint64_t", ffi.cast("void *", programMemory)))
	local pixels = ffi.new("Uint8[?]", options.width * options.height * 3)
	local event = ffi.new("SDL_Event")
	if options.color == "p" then
		local paletteBytes = ffi.new("Uint8[?]", 768)
		for index = 1, 768 do
			paletteBytes[index - 1] = display.palette:byte(index)
		end
		display.palette = paletteBytes
	end

	local function drawFrame(frame)
		for pixel = 0, options.width * options.height - 1 do
			local source = pixel * frameStride
			local red, green, blue
			if options.color == "r" then
				red = frame[source]
				green = frame[source + 1]
				blue = frame[source + 2]
			elseif options.color == "p" then
				local paletteOffset = frame[source] * 3
				red = display.palette[paletteOffset]
				green = display.palette[paletteOffset + 1]
				blue = display.palette[paletteOffset + 2]
			else
				red = frame[source]
				green = red
				blue = red
			end
			local offset = pixel * 3
			pixels[offset] = red
			pixels[offset + 1] = green
			pixels[offset + 2] = blue
		end
		if display.sdl.SDL_UpdateTexture(display.texture, nil, pixels, options.width * 3) ~= 0 then
			io.stderr:write("error: cannot update display: " .. ffi.string(display.sdl.SDL_GetError()) .. "\n")
			return false
		end
		display.sdl.SDL_RenderClear(display.renderer)
		display.sdl.SDL_RenderCopy(display.renderer, display.texture, nil, nil)
		display.sdl.SDL_RenderPresent(display.renderer)
		return true
	end

	local function worker(queueAddress, mutexAddress, programAddress, programLength, inputText, config, audioDevice)
		local ffi = require("ffi")
		ffi.cdef[[
			typedef unsigned char Uint8;
			typedef unsigned int Uint32;
			typedef struct SDL_mutex SDL_mutex;
			int SDL_LockMutex(SDL_mutex *mutex);
			int SDL_UnlockMutex(SDL_mutex *mutex);
			void SDL_Delay(Uint32 ms);
			const char *SDL_GetError(void);
			int SDL_QueueAudio(Uint32 device, const void *data, Uint32 length);
			Uint32 SDL_GetQueuedAudioSize(Uint32 device);
		]]
		local sdl = ffi.load("libSDL2-2.0.so.0")
		local sharedQueue = ffi.cast("Uint32 *", ffi.cast("void *", queueAddress))
		local sharedData = ffi.cast("Uint8 *", ffi.cast("void *", queueAddress)) + 16
		local mutex = ffi.cast("SDL_mutex *", ffi.cast("void *", mutexAddress))
		local frameCapacity, memsize, width, height, color, soundLength, soundOffset =
			config:match("^(%d+),(%d+),(%d+),(%d+),([grp]),(%d+),(%d+)$")
		frameCapacity = tonumber(frameCapacity)
		memsize = tonumber(memsize)
		width = tonumber(width)
		height = tonumber(height)
		soundLength = tonumber(soundLength)
		soundOffset = tonumber(soundOffset)
		local frameStride = color == "r" and 3 or 1
		local frameBytes = width * height * frameStride
		local audio
		if soundLength > 0 then
			local function queueSamples(device, tape, offset, length)
				local samples = ffi.new("Uint8[?]", length)
				for index = 0, length - 1 do
					samples[index] = tape[offset + index] or 0
				end
				if sdl.SDL_QueueAudio(device, samples, length) ~= 0 then
					io.stderr:write("error: cannot queue audio: " .. ffi.string(sdl.SDL_GetError()) .. "\n")
				end
			end
			audio = {
				update = function(device, tape, offset, length)
					if sdl.SDL_GetQueuedAudioSize(device) <= length then
						queueSamples(device, tape, offset, length)
					end
				end,
				enqueue = function(device, tape, offset, length)
					local maximumQueued = length * 8
					while sdl.SDL_GetQueuedAudioSize(device) > maximumQueued do
						sdl.SDL_Delay(1)
					end
					queueSamples(device, tape, offset, length)
				end,
				drain = function(device)
					while sdl.SDL_GetQueuedAudioSize(device) > 0 do
						sdl.SDL_Delay(1)
					end
				end,
				finish = function(device, tape, offset, length)
					while sdl.SDL_GetQueuedAudioSize(device) > length do
						sdl.SDL_Delay(1)
					end
					if sdl.SDL_GetQueuedAudioSize(device) <= length then
						queueSamples(device, tape, offset, length)
					end
					while sdl.SDL_GetQueuedAudioSize(device) > 0 do
						sdl.SDL_Delay(1)
					end
				end,
			}
		end
		local source = ffi.cast("Uint8 *", ffi.cast("void *", programAddress))
		local function enqueue(tape)
			while true do
				sdl.SDL_LockMutex(mutex)
				if sharedQueue[3] ~= 0 then
					sdl.SDL_UnlockMutex(mutex)
					return false
				end
				local head = sharedQueue[0]
				local tail = sharedQueue[1]
				if head - tail < frameCapacity then
					local slot = head % frameCapacity
					local offset = slot * frameBytes
					for pixel = 0, width * height - 1 do
						local cell = pixel * frameStride
						for channel = 0, frameStride - 1 do
							sharedData[offset + cell + channel] = tape[cell + channel] or 0
						end
					end
					sharedQueue[0] = head + 1
					sdl.SDL_UnlockMutex(mutex)
					return true
				end
				sdl.SDL_UnlockMutex(mutex)
				sdl.SDL_Delay(1)
			end
		end

		local tape = {}
		local pointer = 0
		local inputPosition = 1
		local jumps = {}
		local openings = {}
		local hasAudioCommands = false
		for index = 0, programLength - 1 do
			local command = source[index]
			if command == 91 then
				openings[#openings + 1] = index
			elseif command == 93 then
				local opening = table.remove(openings)
				jumps[opening] = index
				jumps[index] = opening
			elseif command == 59 then
				hasAudioCommands = true
			end
		end

		local instruction = 0
		local count = 0
		if audio and not hasAudioCommands then
			audio.update(audioDevice, tape, soundOffset, soundLength)
		end
		while instruction < programLength do
			if count % 1024 == 0 then
				sdl.SDL_LockMutex(mutex)
				local aborted = sharedQueue[3] ~= 0
				sdl.SDL_UnlockMutex(mutex)
				if aborted then
					break
				end
				if audio and not hasAudioCommands then
					audio.update(audioDevice, tape, soundOffset, soundLength)
				end
			end
			local command = source[instruction]
			local value = tape[pointer] or 0
			if command == 62 then
				pointer = (pointer + 1) % memsize
			elseif command == 60 then
				pointer = (pointer - 1) % memsize
			elseif command == 43 then
				tape[pointer] = (value + 1) % 256
			elseif command == 45 then
				tape[pointer] = (value - 1) % 256
			elseif command == 46 then
				io.write(string.char(value))
			elseif command == 44 then
				tape[pointer] = inputText:byte(inputPosition) or 0
				inputPosition = inputPosition + 1
			elseif command == 42 then
				if not enqueue(tape) then
					break
				end
			elseif command == 59 and audio then
				audio.enqueue(audioDevice, tape, soundOffset, soundLength)
			elseif command == 91 and value == 0 then
				instruction = jumps[instruction]
			elseif command == 93 and value ~= 0 then
				instruction = jumps[instruction]
			end
			instruction = instruction + 1
			count = count + 1
		end

		if not enqueue(tape) then
			sdl.SDL_LockMutex(mutex)
			sharedQueue[2] = 1
			sdl.SDL_UnlockMutex(mutex)
			return
		end
		if audio then
			if hasAudioCommands then
				audio.drain(audioDevice)
			else
				audio.finish(audioDevice, tape, soundOffset, soundLength)
			end
		end
		sdl.SDL_LockMutex(mutex)
		sharedQueue[2] = 1
		sdl.SDL_UnlockMutex(mutex)
	end

	display.event = event
	local audioOffset = options.width * options.height * frameStride
	local audioHandle = options.audio and require("./audio").open() or nil
	local config = table.concat({ frameCapacity, options.memsize, options.width, options.height,
		options.color, options.audio and options.soundLength or 0, audioOffset }, ",")
	local thread = uv.new_thread(worker, queueAddress, mutexAddress, programAddress, #program,
		input, config, audioHandle and audioHandle.device or 0)
	local blank = ffi.new("Uint8[?]", frameBytes)
	drawFrame(blank)
	display.lastFrame = display.sdl.SDL_GetTicks64()

	while display.open do
		while display.sdl.SDL_PollEvent(event) ~= 0 do
			if event.type == 0x100 then
				display.open = false
				local sdl = display.sdl
				sdl.SDL_LockMutex(display.mutex)
				queue[3] = 1
				sdl.SDL_UnlockMutex(display.mutex)
				break
			end
		end

		if display.open then
			local now = display.sdl.SDL_GetTicks64()
			if now - display.lastFrame >= display.frameInterval then
				display.sdl.SDL_LockMutex(display.mutex)
				local head = queue[0]
				local tail = queue[1]
				local frame
				if tail < head then
					local slot = tail % frameCapacity
					frame = ffi.new("Uint8[?]", frameBytes)
					ffi.copy(frame, queueData + slot * frameBytes, frameBytes)
					queue[1] = tail + 1
				end
				display.sdl.SDL_UnlockMutex(display.mutex)
				if frame then
					if not drawFrame(frame) then
						display.open = false
					end
					display.lastFrame = now
				end
			end
			display.sdl.SDL_Delay(1)
		end
	end

	uv.thread_join(thread)
	if audioHandle then
		require("./audio").close(audioHandle)
	end
	display.sdl.SDL_DestroyMutex(display.mutex)
	display.sdl.SDL_DestroyTexture(display.texture)
	display.sdl.SDL_DestroyRenderer(display.renderer)
	display.sdl.SDL_DestroyWindow(display.window)
	display.sdl.SDL_Quit()
end

return M
