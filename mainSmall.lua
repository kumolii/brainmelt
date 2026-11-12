-- brainmelt

local process = process or require("process").globalProcess()
local args = require("./args")
local readAll = require("./file").readAll
local brainfuck = require("./brainfuck")

local options, positional = args.parse(process.argv)

if #positional < 1 or #positional > 2 then
	io.stderr:write("kumolii/brainmelt (small) | my low quality brainfuck interpreter\n\n")
	io.stderr:write("usage: brainmelt [options] <program.bf|-> [input-file|-]\n")
	io.stderr:write("options: -m, --memsize N\n")
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

brainfuck.executeProgram(program, input, options.memsize, process.stdout, options)
