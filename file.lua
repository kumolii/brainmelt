local M = {}

function M.readAll(path, description, embedded)
	local file
	if path == "-" then
		file = io.stdin
	else
		if embedded then
			local ok, luvi = pcall(require, "luvi")
			if ok and luvi.bundle and luvi.bundle.readfile then
				local contents = luvi.bundle.readfile(path)
				if contents ~= nil then
					return contents
				end
			end
		end
		local err
		file, err = io.open(path, "rb")
		if not file then
			io.stderr:write("error: cannot open " .. description .. " '" .. path .. "': " .. err .. "\n")
			os.exit(1)
		end
	end

	local contents = file:read("*a")
	if path ~= "-" then
		file:close()
	end
	return contents or ""
end

return M
