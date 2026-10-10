-- Versioned static-level exporter for the Peggle Evolved interchange.
--
-- Runs under plain LuaJIT against the pinned Lua reference. Emits the
-- `peggle.level` schema v1 artifact from a level module, after applying the
-- same load-time pipeline the engine applies before peg colors are assigned:
--
--     level module load
--     -> peg entity normalization (Engine:setupLevel)
--     -> Lines.validate
--     -> boundary filtering (LevelValidator.validate_pegs)
--     -> Lines.validate
--     -> original_index assignment
--
-- Motion is rejected explicitly. The v1 static subset supports levels whose
-- `level_circuits` is empty (or absent) and whose pegs carry no `motion`
-- assignment. Circuit primitives and legacy `path_fn` functions both fail
-- with a clear error instead of being silently dropped.
--
-- Usage:
--   luajit tools/export_level.lua --level NAME [--out FILE] [--check]
--   luajit tools/export_level.lua --list [--static|--moving]
--
-- Options:
--   --level NAME          level module name under src/levels
--   --out FILE            write the artifact to FILE (default: stdout)
--   --check               round-trip the artifact and verify it against the
--                         live level state; aborts on any mismatch
--   --reference DIR       pinned reference root (default: <repo>/reference/peggle_evolved)
--   --revision REV        reference revision for provenance
--   --tree TREE           reference tree hash for provenance
--   --config-sha256 SHA   config file hash for provenance
--   --list                list levels and their motion class, one per line
--   --static              with --list: print only static level names
--   --moving              with --list: print only moving level names

local script_dir = (debug.getinfo(1, "S").source:match("@(.*)/[^/]*$")) or "."
local repo_root = script_dir .. "/.."

-- Headless love stub: LevelManager.load resolves the per-level virtual
-- resolution and calls Screen.resize, which needs window dimensions. No
-- rendering code is reached.
if not _G.love then
	_G.love = {
		graphics = { getDimensions = function() return 1920, 1080 end },
	}
end

-- ===========================================================================
-- CLI
-- ===========================================================================
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
local LevelManager = require("src.systems.level_manager")
local Peg = require("src.entities.peg")
local Lines = require("src.systems.lines")
local MotionSchema = require("src.systems.motion_schema")
local Validator = require("src.systems.level_validator")

local function die(message, code)
	io.stderr:write("export_level: " .. message .. "\n")
	os.exit(code or 1)
end

-- ===========================================================================
-- Motion classification
-- ===========================================================================

-- Return every reason the level is not in the v1 static subset.
local function motion_violations(level_data, pegs)
	local violations = {}
	local circuits = level_data.level_circuits
	if circuits ~= nil and next(circuits) ~= nil then
		local ids = {}
		for id in pairs(circuits) do ids[#ids + 1] = tostring(id) end
		table.sort(ids)
		for _, id in ipairs(ids) do
			local def = circuits[id]
			if type(def) == "table" and type(def.path_fn) == "function" then
				violations[#violations + 1] = string.format(
					"circuit %q uses a legacy path_fn function; arbitrary Lua path functions are not supported by the v1 interchange (migrate to a primitive kind or defer to the moving-level phase)", id)
			elseif type(def) == "table" and def.kind ~= nil then
				violations[#violations + 1] = string.format(
					"circuit %q uses motion primitive kind %q; moving levels are out of scope for the v1 static interchange", id, tostring(def.kind))
			else
				violations[#violations + 1] = string.format(
					"circuit %q is not a static definition; moving levels are out of scope for the v1 static interchange", id)
			end
		end
	end
	local moving_first, moving_count = nil, 0
	for i, p in ipairs(pegs) do
		if p.motion ~= nil then
			moving_count = moving_count + 1
			if moving_first == nil then moving_first = i end
		end
	end
	if moving_count > 0 then
		violations[#violations + 1] = string.format(
			"%d peg(s) carry a motion assignment (first: peg %d); moving pegs are out of scope for the v1 static interchange",
			moving_count, moving_first)
	end
	return violations
end

-- Load a level module and classify it without building the artifact.
local function classify_level(name)
	local level_data = LevelManager.load(name)
	local raw = level_data.pegs or {}
	local circuits = level_data.level_circuits
	local moving = (circuits ~= nil and next(circuits) ~= nil)
	if not moving then
		for _, p in ipairs(raw) do
			if p.motion ~= nil then
				moving = true
				break
			end
		end
	end
	return moving
end

-- ===========================================================================
-- Static level build (mirrors Engine:setupLevel up to color assignment)
-- ===========================================================================
local function build_static_level(name)
	local level_data = LevelManager.load(name)

	-- Peg normalization, exactly Engine:setupLevel (src/engine/core.lua).
	local pegs = {}
	for _, p in ipairs(level_data.pegs or {}) do
		if p.radius and p.base_x then
			pegs[#pegs + 1] = p
		else
			local new_p = Peg.new(p.x, p.y, p.type, p.radius)
			for k, v in pairs(p) do
				new_p[k] = v
			end
			pegs[#pegs + 1] = new_p
		end
	end

	local violations = motion_violations(level_data, pegs)
	if #violations > 0 then
		return nil, violations
	end

	-- Mirror Engine:setupLevel load-time validation. With no circuits this
	-- still rejects legacy peg motion fields (circuit_id/circuit_t/...).
	MotionSchema.validate(pegs, {})

	Lines.validate(pegs)
	pegs = Validator.validate_pegs(pegs, {})
	Lines.validate(pegs)
	for i, p in ipairs(pegs) do
		p.original_index = i
	end

	local type_counts = level_data.type_counts or { red = 10, green = 2 }
	local red = type_counts.red or 0
	local green = type_counts.green or 0
	local effective_counts = {
		blue = #pegs - (red + green),
		green = green,
		purple = type_counts.purple or 0,
		red = red,
	}
	local level_seed = level_data.level_seed or 345

	return {
		name = name,
		level_data = level_data,
		pegs = pegs,
		type_counts = effective_counts,
		level_seed = level_seed,
	}
end

-- ===========================================================================
-- Canonical artifact
-- ===========================================================================
local function canonical_line(line)
	return {
		id = line.id,
		index = line.index,
		count = line.count,
		closed = line.closed,
		gap = line.gap,
	}
end

-- Peg.new accepts any `type` value; the engine's typeDef falls back to the
-- default for unknown types, and PegColors.init overwrites every type from
-- the seeded pool before gameplay. The artifact records the resolved render
-- type (known string or default) so the field is always a valid enum.
local function normalize_type(peg_type)
	if type(peg_type) == "string" and Config.peg_types[peg_type] ~= nil then
		return peg_type
	end
	return Config.default_peg_type
end

local function canonical_peg(p, id)
	local shape = p.shape or "circle"
	local peg = {
		id = id,
		shape = shape,
		type = normalize_type(p.type),
		x = p.x,
		y = p.y,
	}
	if shape == "circle" then
		peg.radius = p.radius
	elseif shape == "rectangle" then
		peg.width = p.width
		peg.height = p.height
		peg.angle = p.angle or 0
	elseif shape == "annular" then
		peg.r_in = p.r_in
		peg.r_out = p.r_out
		peg.theta_start = p.theta_start
		peg.theta_end_abs = p.theta_end_abs
		peg.segments = p.segments
	else
		error("export_level: unknown peg shape " .. tostring(shape))
	end
	if p.line ~= nil then
		peg.line = canonical_line(p.line)
	end
	return peg
end

local function build_artifact(built, provenance)
	local pegs = {}
	for i, p in ipairs(built.pegs) do
		pegs[#pegs + 1] = canonical_peg(p, i)
	end
	return {
		format = "peggle.level",
		schema_version = 1,
		name = built.name,
		motion = "static",
		virtual_width = LevelManager.virtual_width,
		virtual_height = LevelManager.virtual_height,
		level_seed = built.level_seed,
		type_counts = built.type_counts,
		default_peg_type = Config.default_peg_type,
		pegs = pegs,
		provenance = provenance,
	}
end

-- ===========================================================================
-- Round-trip verification
-- ===========================================================================

-- Compare two canonical values. Numbers must have identical canonical
-- encoding (bit-level intent preserved, including signed zero); arrays must
-- keep order; objects must have the same key set. Returns nil, or an error
-- path describing the first difference.
local function compare(a, b, path)
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return path .. ": type " .. ta .. " ~= " .. tb
	end
	if ta == "number" then
		if CanonicalJSON.encode(a) ~= CanonicalJSON.encode(b) then
			return path .. ": " .. string.format("%.17g", a) .. " ~= " .. string.format("%.17g", b)
		end
		return nil
	elseif ta ~= "table" then
		if a ~= b then return path .. ": " .. tostring(a) .. " ~= " .. tostring(b) end
		return nil
	end
	local function is_array(v)
		local n = 0
		for k in pairs(v) do
			if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
			n = n + 1
		end
		for i = 1, n do if v[i] == nil then return false end end
		return true, n
	end
	local a_array, a_n = is_array(a)
	local b_array, b_n = is_array(b)
	if a_array ~= b_array then return path .. ": array/object mismatch" end
	if a_array then
		if a_n ~= b_n then return path .. ": length " .. a_n .. " ~= " .. b_n end
		for i = 1, a_n do
			local err = compare(a[i], b[i], path .. "[" .. i .. "]")
			if err then return err end
		end
		return nil
	end
	local keys = {}
	for k in pairs(a) do keys[k] = true end
	for k in pairs(b) do
		if not keys[k] then return path .. ": unexpected key " .. tostring(k) end
		keys[k] = nil
	end
	for k in pairs(keys) do return path .. ": missing key " .. tostring(k) end
	local sorted = {}
	for k in pairs(a) do sorted[#sorted + 1] = k end
	table.sort(sorted)
	for _, k in ipairs(sorted) do
		local err = compare(a[k], b[k], path .. "." .. k)
		if err then return err end
	end
	return nil
end

-- The round-trip check:
--   1. artifact -> canonical text -> decoded artifact -> canonical text is
--      byte-identical (numeric serialization, key order, array order);
--   2. the decoded artifact equals the in-memory artifact under bit-level
--      numeric comparison (identifiers, dimensions, geometry, line metadata);
--   3. every decoded peg matches the live resolved peg it came from.
local function check_roundtrip(artifact, text, built)
	local decoded = CanonicalJSON.decode(text)
	local reencoded = CanonicalJSON.encode(decoded)
	if reencoded ~= text then
		-- Locate the first differing byte for a useful message.
		local limit = math.min(#reencoded, #text)
		local pos = 1
		while pos <= limit and reencoded:sub(pos, pos) == text:sub(pos, pos) do pos = pos + 1 end
		return string.format("text round-trip differs at byte %d", pos)
	end

	local err = compare(artifact, decoded, "$")
	if err then return "artifact round-trip " .. err end

	if #decoded.pegs ~= #built.pegs then
		return string.format("peg count %d ~= live %d", #decoded.pegs, #built.pegs)
	end
	for i, live in ipairs(built.pegs) do
		local dp = decoded.pegs[i]
		if dp.id ~= i then return string.format("peg %d has id %s", i, tostring(dp.id)) end
		if dp.x ~= live.x or dp.y ~= live.y then
			return string.format("peg %d position differs", i)
		end
		if dp.type ~= normalize_type(live.type) then
			return string.format("peg %d type differs", i)
		end
		local shape = live.shape or "circle"
		if dp.shape ~= shape then return string.format("peg %d shape differs", i) end
		if shape == "circle" and dp.radius ~= live.radius then
			return string.format("peg %d radius differs", i)
		elseif shape == "rectangle" then
			if dp.width ~= live.width or dp.height ~= live.height
				or dp.angle ~= (live.angle or 0) then
				return string.format("peg %d rectangle geometry differs", i)
			end
		elseif shape == "annular" then
			if dp.r_in ~= live.r_in or dp.r_out ~= live.r_out
				or dp.theta_start ~= live.theta_start
				or dp.theta_end_abs ~= live.theta_end_abs
				or dp.segments ~= live.segments then
				return string.format("peg %d annular geometry differs", i)
			end
		end
		local has_line = live.line ~= nil
		if (dp.line ~= nil) ~= has_line then
			return string.format("peg %d line metadata presence differs", i)
		end
		if has_line then
			local a, b = dp.line, live.line
			if a.id ~= b.id or a.index ~= b.index or a.count ~= b.count
				or a.closed ~= b.closed or a.gap ~= b.gap then
				return string.format("peg %d line metadata differs", i)
			end
		end
	end

	-- Identifiers: contiguous 1..n, matching the level order.
	for i = 1, #decoded.pegs do
		if decoded.pegs[i].id ~= i then
			return "peg identifiers are not contiguous in level order"
		end
	end
	return nil
end

-- ===========================================================================
-- Entry point
-- ===========================================================================
local function list_levels()
	local dir = ref_root .. "/src/levels"
	local pipe = io.popen('ls "' .. dir .. '" 2>/dev/null')
	if not pipe then die("cannot list " .. dir) end
	local names = {}
	for line in pipe:lines() do
		local name = line:match("^([%w_]+)%.lua$")
		if name then names[#names + 1] = name end
	end
	pipe:close()
	table.sort(names)
	local rows = {}
	for _, name in ipairs(names) do
		local ok, moving = pcall(classify_level, name)
		if ok then
			rows[#rows + 1] = { name = name, moving = moving }
		else
			rows[#rows + 1] = { name = name, error = tostring(moving) }
		end
	end
	for _, row in ipairs(rows) do
		if args.static then
			if row.error == nil and not row.moving then print(row.name) end
		elseif args.moving then
			if row.error == nil and row.moving then print(row.name) end
		else
			local kind = row.error and ("error: " .. row.error) or (row.moving and "moving" or "static")
			print(row.name .. "\t" .. kind)
		end
	end
end

if args.list then
	list_levels()
	os.exit(0)
end

local level_name = args.level
if type(level_name) ~= "string" then
	die("--level NAME is required (or use --list)", 1)
end

local provenance = {
	reference_revision = args.revision or nil,
	reference_tree = args.tree or nil,
	config_sha256 = args["config-sha256"] or nil,
	level_source = "reference/peggle_evolved/src/levels/" .. level_name .. ".lua",
}

local built, violations = build_static_level(level_name)
if not built then
	io.stderr:write("export_level: level " .. level_name
		.. " is not in the v1 static subset:\n")
	for _, v in ipairs(violations) do
		io.stderr:write("  - " .. v .. "\n")
	end
	os.exit(2)
end

local artifact = build_artifact(built, provenance)
local text = CanonicalJSON.encode(artifact)

if args.check then
	local err = check_roundtrip(artifact, text, built)
	if err then
		die("round-trip check failed for " .. level_name .. ": " .. err, 3)
	end
end

local out_path = args.out
if type(out_path) == "string" then
	local f, ferr = io.open(out_path, "w")
	if not f then die("cannot write " .. out_path .. ": " .. tostring(ferr), 4) end
	f:write(text)
	f:write("\n")
	f:close()
	if args.check then
		print(string.format("export_level: %s -> %s (%d pegs, round-trip OK)",
			level_name, out_path, #artifact.pegs))
	end
else
	print(text)
end
