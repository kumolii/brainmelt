local ffi = require("ffi")

ffi.cdef[[
	typedef struct SDL_AudioSpec {
		int freq;
		unsigned short format;
		unsigned char channels;
		unsigned char silence;
		unsigned short samples;
		unsigned short padding;
		unsigned int size;
		void (*callback)(void *, unsigned char *, int);
		void *userdata;
	} SDL_AudioSpec;
	int SDL_InitSubSystem(unsigned int flags);
	void SDL_QuitSubSystem(unsigned int flags);
	const char *SDL_GetError(void);
	unsigned int SDL_OpenAudioDevice(const char *device, int capture,
		const SDL_AudioSpec *desired, SDL_AudioSpec *obtained, int allowed_changes);
	void SDL_CloseAudioDevice(unsigned int device);
	void SDL_PauseAudioDevice(unsigned int device, int pause_on);
	int SDL_QueueAudio(unsigned int device, const void *data, unsigned int length);
	unsigned int SDL_GetQueuedAudioSize(unsigned int device);
	void SDL_ClearQueuedAudio(unsigned int device);
	void SDL_Delay(unsigned int ms);
]]

local M = {}
local sdl

local function loadSDL()
	if sdl then
		return sdl
	end
	local loaded, library = pcall(ffi.load, "libSDL2-2.0.so.0")
	if not loaded then
		io.stderr:write("error: cannot load SDL2: " .. tostring(library) .. "\n")
		os.exit(1)
	end
	sdl = library
	return sdl
end

function M.open()
	local library = loadSDL()
	if library.SDL_InitSubSystem(0x10) ~= 0 then
		io.stderr:write("error: SDL audio initialization failed: " .. ffi.string(library.SDL_GetError()) .. "\n")
		os.exit(1)
	end
	local desired = ffi.new("SDL_AudioSpec")
	desired.freq = 8000
	desired.format = 0x0008
	desired.channels = 1
	desired.samples = 512
	local device = library.SDL_OpenAudioDevice(nil, 0, desired, nil, 0)
	if device == 0 then
		io.stderr:write("error: cannot open audio device: " .. ffi.string(library.SDL_GetError()) .. "\n")
		library.SDL_QuitSubSystem(0x10)
		os.exit(1)
	end
	library.SDL_PauseAudioDevice(device, 0)
	return { device = device }
end

function M.update(device, tape, offset, length)
	local library = loadSDL()
	if library.SDL_GetQueuedAudioSize(device) > length then
		return
	end
	local samples = ffi.new("unsigned char[?]", length)
	for index = 0, length - 1 do
		samples[index] = tape[offset + index] or 0
	end
	if library.SDL_QueueAudio(device, samples, length) ~= 0 then
		io.stderr:write("error: cannot queue audio: " .. ffi.string(library.SDL_GetError()) .. "\n")
	end
end

function M.enqueue(device, tape, offset, length)
	local library = loadSDL()
	local maximumQueued = length * 8
	while library.SDL_GetQueuedAudioSize(device) > maximumQueued do
		library.SDL_Delay(1)
	end
	local samples = ffi.new("unsigned char[?]", length)
	for index = 0, length - 1 do
		samples[index] = tape[offset + index] or 0
	end
	if library.SDL_QueueAudio(device, samples, length) ~= 0 then
		io.stderr:write("error: cannot queue audio: " .. ffi.string(library.SDL_GetError()) .. "\n")
	end
end

function M.drain(device)
	local library = loadSDL()
	while library.SDL_GetQueuedAudioSize(device) > 0 do
		library.SDL_Delay(1)
	end
end

function M.finish(device, tape, offset, length)
	local library = loadSDL()
	while library.SDL_GetQueuedAudioSize(device) > length do
		library.SDL_Delay(1)
	end
	M.update(device, tape, offset, length)
	M.drain(device)
end

function M.close(handle)
	local library = loadSDL()
	library.SDL_ClearQueuedAudio(handle.device)
	library.SDL_CloseAudioDevice(handle.device)
	library.SDL_QuitSubSystem(0x10)
end

return M