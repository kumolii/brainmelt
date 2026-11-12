local scriptPath = process.argv[1]
local scriptDirectory = scriptPath:match("^(.*[/\\])") or ""
local palettePath = scriptDirectory .. "palette.bin"
local palette, err = io.open(palettePath, "wb")
if not palette then
	io.stderr:write("error: cannot create palette '" .. palettePath .. "': " .. err .. "\n")
	os.exit(1)
end

local function writeColor(red, green, blue)
	palette:write(string.char(red, green, blue))
end

local ansiColors = {
	{ 0, 0, 0 }, { 205, 0, 0 }, { 0, 205, 0 }, { 205, 205, 0 },
	{ 0, 0, 238 }, { 205, 0, 205 }, { 0, 205, 205 }, { 229, 229, 229 },
	{ 127, 127, 127 }, { 255, 0, 0 }, { 0, 255, 0 }, { 255, 255, 0 },
	{ 92, 92, 255 }, { 255, 0, 255 }, { 0, 255, 255 }, { 255, 255, 255 },
}

for _, color in ipairs(ansiColors) do
	writeColor(color[1], color[2], color[3])
end

local cubeLevels = { 0, 95, 135, 175, 215, 255 }
for _, red in ipairs(cubeLevels) do
	for _, green in ipairs(cubeLevels) do
		for _, blue in ipairs(cubeLevels) do
			writeColor(red, green, blue)
		end
	end
end

for index = 0, 23 do
	local gray = 8 + index * 10
	writeColor(gray, gray, gray)
end

palette:close()