-- Versioned configuration exporter for the Peggle Evolved interchange.
--
-- Emits the `peggle.config` schema v1 artifact from the pinned reference's
-- src/config.lua. Only JSON data types are allowed; functions and other
-- non-data values abort the export instead of vanishing silently.
--
-- Usage:
--   luajit tools/export_config.lua [--out FILE] [--check]
--     [--reference DIR] [--source-sha256 SHA]
--
-- Options:
--   --out FILE           write the artifact to FILE (default: stdout)
--   --check              decode/encode round-trip verification
--   --reference DIR      pinned reference root
--   --source-sha256 SHA  hash of src/config.lua for provenance

local script_dir = (debug.getinfo(1, "S").source:match("@(.*)/[^/]*$")) or "."
local repo_root = script_dir .. "/.."

local function parse_args(argv)
	local args = {}
	local i = 1
	while i <= #argv do
		local tok = argv[i]
		if type(tok) == "string" and tok:sub(1, 2) == "--" then
			local key = tok:sub(3)
			local nxt = argv[i + 1]
			if nxt ~= nil and nxt:sub(1, 2) ~= "--" then
				args[key] = nxt
				i = i + 1
			else
				args[key] = true
			end
		end
		i = i + 1
	end
	return args
end

local args = parse_args(rawget(_G, "arg") or {})
local ref_root = args.reference or (repo_root .. "/reference/peggle_evolved")
if ref_root:sub(1, 1) ~= "/" then
	ref_root = repo_root .. "/" .. ref_root
end

package.path = script_dir .. "/?.lua;" .. ref_root .. "/?.lua;"
	.. ref_root .. "/?/init.lua;" .. package.path

local CanonicalJSON = require("canonical_json")
local Config = require("src.config")

local function die(message, code)
	io.stderr:write("export_config: " .. message .. "\n")
	os.exit(code or 1)
end

local function copy_data(value, path)
	local t = type(value)
	if value == nil or t == "number" or t == "string" or t == "boolean" then
		return value
	elseif t == "table" then
		local out = {}
		local keys = {}
		for k in pairs(value) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, k in ipairs(keys) do
			if type(k) ~= "string" and type(k) ~= "number" then
				die("config key at " .. path .. " has type " .. type(k))
			end
			out[k] = copy_data(value[k], path .. "." .. tostring(k))
		end
		return out
	else
		die("config value at " .. path .. " has non-data type " .. t)
	end
end

local artifact = {
	format = "peggle.config",
	schema_version = 1,
	source_sha256 = args["source-sha256"] or nil,
	values = copy_data(Config, "config"),
}

local text = CanonicalJSON.encode(artifact)

if args.check then
	local decoded = CanonicalJSON.decode(text)
	local reencoded = CanonicalJSON.encode(decoded)
	if reencoded ~= text then
		die("config round-trip differs", 3)
	end
end

local out_path = args.out
if type(out_path) == "string" then
	local f, err = io.open(out_path, "w")
	if not f then die("cannot write " .. out_path .. ": " .. tostring(err), 4) end
	f:write(text)
	f:write("\n")
	f:close()
	if args.check then
		print("export_config: " .. out_path .. " (round-trip OK)")
	end
else
	print(text)
end
