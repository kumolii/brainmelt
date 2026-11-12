--    ░████████                       ░██                                      ░██    ░██    
--    ░██    ░██                                                               ░██    ░██    
--    ░██    ░██  ░██░████  ░██████   ░██░████████  ░█████████████   ░███████  ░██ ░████████ 
--    ░████████   ░███           ░██  ░██░██    ░██ ░██   ░██   ░██ ░██    ░██ ░██    ░██    
--    ░██     ░██ ░██       ░███████  ░██░██    ░██ ░██   ░██   ░██ ░█████████ ░██    ░██    
--    ░██     ░██ ░██      ░██   ░██  ░██░██    ░██ ░██   ░██   ░██ ░██        ░██    ░██    
--    ░█████████  ░██       ░█████░██ ░██░██    ░██ ░██   ░██   ░██  ░███████  ░██     ░████ 
--                     kumolii/brainmelt | my low quality brainfuck interpreter 

local process = process or require("process").globalProcess()

local args = require("./args")
local readAll = require("./file").readAll
local brainfuck = require("./brainfuck")
local display = require("./display")

local options, positional = args.parse(process.argv)

local titleLines = {
	"    ░████████                       ░██                                      ░██    ░██    ","    ░██    ░██                                                               ░██    ░██    ","    ░██    ░██  ░██░████  ░██████   ░██░████████  ░█████████████   ░███████  ░██ ░████████ ","    ░████████   ░███           ░██  ░██░██    ░██ ░██   ░██   ░██ ░██    ░██ ░██    ░██    ","    ░██     ░██ ░██       ░███████  ░██░██    ░██ ░██   ░██   ░██ ░█████████ ░██    ░██    ","    ░██     ░██ ░██      ░██   ░██  ░██░██    ░██ ░██   ░██   ░██ ░██        ░██    ░██    ","    ░█████████  ░██       ░█████░██ ░██░██    ░██ ░██   ░██   ░██  ░███████  ░██     ░████ ",
}
local prideFlags = {{{255,0,24},{255,165,44},{255,255,65},{0,128,24},{0,0,249},{134,0,125}},{{91,206,250},{245,169,184},{245,245,245},{245,169,184},{91,206,250}},{{214,2,112},{155,79,150},{0,56,168}},{{255,33,140},{255,216,0},{33,177,255}},{{255,244,48},{245,245,245},{156,89,209},{45,45,45}},{{20,20,20},{163,163,163},{245,245,245},{128,0,128}},{{59,169,62},{168,212,120},{245,245,245},{169,169,169},{20,20,20}},{{213,45,0},{239,124,0},{245,245,245},{209,98,164},{163,2,98}},{{20,20,20},{188,196,198},{245,245,245},{181,240,118},{245,245,245},{188,196,198},{20,20,20}},{{255,118,164},{245,245,245},{190,25,221},{20,20,20},{47,56,198}},{{245,245,245},{210,162,213},{128,0,128},{20,20,20}},{{127,127,127},{195,224,231},{91,206,250},{245,245,245},{91,206,250},{195,224,231},{127,127,127}},{{127,127,127},{244,196,218},{245,169,184},{245,245,245},{245,169,184},{244,196,218},{127,127,127}},{{20,20,20},{185,185,185},{245,245,245},{186,244,124},{245,245,245},{185,185,185},{20,20,20}},{{247,214,0},{121,0,128}},{{247,19,148},{7,211,88},{0,181,241}}}
if #positional < 1 or #positional > 2 then
	math.randomseed(os.time() + (tonumber(process.pid) or 0) + math.floor(os.clock() * 1000000))
	local frenchFlag = {{0, 0, 145}, {255, 255, 255}, {237, 41, 57}}
	local isFrenchFlag = math.random(100) == 1
	local palette = isFrenchFlag and frenchFlag or prideFlags[math.random(#prideFlags)]
	for index, line in ipairs(titleLines) do
		if isFrenchFlag then
			local totalColumns = 0
			for position = 1, #line do
				local byte = line:byte(position)
				if byte < 128 or byte >= 192 then
					totalColumns = totalColumns + 1
				end
			end
			local column = 0
			local position = 1
			while position <= #line do
				local firstByte = line:byte(position)
				local characterLength = firstByte >= 240 and 4 or firstByte >= 224 and 3 or firstByte >= 192 and 2 or 1
				local character = line:sub(position, position + characterLength - 1)
				column = column + 1
				local color = frenchFlag[math.floor((column - 1) * #frenchFlag / totalColumns) + 1]
				io.stderr:write(string.format("\27[38;2;%d;%d;%dm%s", color[1], color[2], color[3], character))
				position = position + characterLength
			end
			io.stderr:write("\27[0m\n")
		else
			local colorIndex = math.floor((index - 1) * #palette / #titleLines) + 1
			local color = palette[colorIndex]
			io.stderr:write(string.format("\27[38;2;%d;%d;%dm%s\27[0m\n", color[1], color[2], color[3], line))
		end
	end
	io.stderr:write("                     kumolii/brainmelt | my low quality brainfuck interpreter\n\n")
	io.stderr:write("usage: brainmelt [options] <program.bf|-> [input-file|-]\n")
	io.stderr:write("options: -m, --memsize N  -d, --display  -t, --test  -w, --width N  -h, --height N\n")
	io.stderr:write("         -s, --size N      -c, --color g|r|p  -f, --maxfps N\n")
	io.stderr:write("         -a, --audio       -l, -soundLength N\n")
	os.exit(1)
end
if options.color ~= "g" and options.color ~= "r" and options.color ~= "p" then
	io.stderr:write("error: color must be 'g', 'r', or 'p'\n")
	os.exit(1)
end
local displayCells = options.display and options.width * options.height * (options.color == "r" and 3 or 1) or 0
if options.audio and displayCells + options.soundLength > options.memsize then
	io.stderr:write("error: display and audio cells exceed memory size\n")
	os.exit(1)
end

local programPath = options.test and ("./tests/" .. positional[1] .. ".bf") or positional[1]
local inputPath = positional[2]

local program = readAll(programPath, "program", options.test)
local input
if inputPath then
	if programPath == "-" and inputPath == "-" then
		io.stderr:write("error: source and program input cannot both use stdin\n")
		os.exit(1)
	end
	input = readAll(inputPath, "input")
elseif programPath == "-" then
	input = ""
else
	input = readAll("-", "input")
end

if not options.display then
	brainfuck.executeProgram(program, input, options.memsize, process.stdout, options)
else
	display.runDisplay(options, program, input)
end
