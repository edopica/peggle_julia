local script_dir = debug.getinfo(1, "S").source:match("@(.*)/.*$") or "."
if script_dir:sub(-5) == "tools" then
	package.path = package.path .. ";" .. script_dir .. "/../?.lua"
end

local JSON = require("tools.json")
local Path = require("src.systems.path")

local function dump_point(p)
	return { x = p.x, y = p.y }
end

-- Data-only source segment: only the fields Path.new accepts. Runtime caches
-- (length, table_s, compiled arc endpoints) are not part of the format.
local function dump_segment(segment)
	local kind = segment.kind
	if kind == "line" then
		return { kind = "line", p0 = dump_point(segment.p0), p1 = dump_point(segment.p1) }
	elseif kind == "arc" then
		return {
			kind = "arc",
			center = dump_point(segment.center),
			radius = segment.radius,
			theta_start = segment.theta_start,
			sweep = segment.sweep,
		}
	elseif kind == "cubic" then
		return {
			kind = "cubic",
			p0 = dump_point(segment.p0),
			c1 = dump_point(segment.c1),
			c2 = dump_point(segment.c2),
			p1 = dump_point(segment.p1),
		}
	end
	return nil
end

-- Convert a compiled Path into an ordered, data-only definition. Metatables
-- and runtime caches are intentionally dropped; compiled Path objects never
-- appear in the dump. Approximation metadata is preserved when present
-- because reconstruction depends on it.
local function dump_path(path)
	local def = {
		segments = {},
		closed = path.closed == true,
	}
	for i, segment in ipairs(path.segments) do
		def.segments[i] = dump_segment(segment)
	end
	if path.source_kind ~= nil then
		def.source_kind = path.source_kind
	end
	if path.curve_tolerance ~= nil then
		def.curve_tolerance = path.curve_tolerance
	end
	if path.approximation_error_bound ~= nil then
		def.approximation_error_bound = path.approximation_error_bound
	end
	return def
end

local function main()
    local level_path = arg[1] or "src/levels/level1.lua"
    local level_data = loadfile(level_path)()

    local out_json = io.open("level_dump.json", "w")
    
    local pegs = {}
    local next_id = 1
    for i, p in ipairs(level_data.pegs or {}) do
        p.id = next_id
        p.peg_index = i -- stable index used in tie-breaking
        table.insert(pegs, p)
        next_id = next_id + 1
    end
    level_data.pegs = pegs

    if level_data.level_circuits then
        for id, circ in pairs(level_data.level_circuits) do
            if type(circ.path_fn) == "function" then
                print("WARNING: level uses path_fn in circuit " .. id .. ", converting to kind=unknown")
                circ.kind = circ.kind or "unknown"
                circ.path_fn = nil
            end
            if circ.kind == "path" then
                if Path.is_path(circ.path) then
                    circ.path = dump_path(circ.path)
                else
                    print("WARNING: circuit " .. id .. " has kind=path without a compiled Path; omitting path")
                    circ.path = nil
                end
            end
        end
    end

    out_json:write(JSON.stringify(level_data))
    out_json:close()
    print("Dumped level to level_dump.json")
end

main()
