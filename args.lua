local M = {}

local valueOptions = {
	["-m"] = "memsize", ["--memsize"] = "memsize",
	["-w"] = "width", ["--width"] = "width",
	["-h"] = "height", ["--height"] = "height",
	["-s"] = "size", ["--size"] = "size",
	["-c"] = "color", ["--color"] = "color",
	["-f"] = "maxfps", ["--maxfps"] = "maxfps",
	["-l"] = "soundLength", ["--soundLength"] = "soundLength",
	["--soundLength"] = "soundLength",
}

function M.parse(argv)
	local options = {
		memsize = 30000,
		display = false,
		width = 30,
		height = 30,
		size = 10,
		color = "g",
		maxfps = 30,
		audio = false,
		soundLength = 10,
		test = false,
	}
	local positional = {}
	local argumentIndex = 1
	if argv[1] == "main.lua" or (argv[1] and argv[1]:match("[/\\]main%.lua$")) then
		argumentIndex = 2
	end
	while argumentIndex <= #argv do
		local argument = argv[argumentIndex]
		if argument == "-d" or argument == "--display" then
			options.display = true
		elseif argument == "-a" or argument == "--audio" then
			options.audio = true
		elseif argument == "-t" or argument == "--test" then
			options.test = true
		elseif valueOptions[argument] then
			argumentIndex = argumentIndex + 1
			local value = argv[argumentIndex]
			if not value then
				io.stderr:write("error: missing value for " .. argument .. "\n")
				os.exit(1)
			end
			local option = valueOptions[argument]
			if option == "color" then
				options.color = value
			else
				local number = tonumber(value)
				if not number or number < 1 or number % 1 ~= 0 then
					io.stderr:write("error: " .. argument .. " must be a positive integer\n")
					os.exit(1)
				end
				options[option] = number
			end
		elseif argument:sub(1, 1) == "-" and argument ~= "-" then
			io.stderr:write("error: unknown option '" .. argument .. "'\n")
			os.exit(1)
		else
			positional[#positional + 1] = argument
		end
		argumentIndex = argumentIndex + 1
	end
	return options, positional
end

return M
