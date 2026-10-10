-- WP-D2 backend engagement probe.
--
-- Runs under plain LuaJIT against the peggle_evolved development tree
-- (--detmath-root) and emits canonical JSON with the selected detmath
-- backend identity plus a fixed set of authoritative probe results. The
-- probes are inputs where the system libm and CORE-MATH backends are known to
-- differ, so comparing the system_libm and core_math probe files proves that
-- the state capture used the requested backend implementation.
--
-- Usage:
--   PEGGLE_MATH_BACKEND=core_math luajit tools/wpd_backend_probe.lua \
--     --detmath-root ../peggle_evolved --out tmp/core-math/state-core_math/backend-identity.json

local script_dir = (debug.getinfo(1, "S").source:match("@(.*)/[^/]*$")) or "."
package.path = script_dir .. "/?.lua;" .. package.path

local ffi = require("ffi")
local CanonicalJSON = require("canonical_json")

local BitUnion = ffi.typeof(
	"union { double d; uint64_t u; uint32_t w[2]; }")

local function bits_hex(x)
	local u = BitUnion()
	u.d = x
	return string.format("0x%016x", u.u)
end

-- Parse a 16-hex-digit bit pattern without passing through a Lua double
-- (which would lose the low bits). The 32-bit halves overlay is valid on
-- every supported little-endian target (linux-x86_64, windows-x86_64,
-- darwin-aarch64); w[0] is the low word.
local function double_of_bits(hex)
	local digits = hex:match("^0[xX](%x+)$")
	if digits == nil or #digits > 16 then
		error("wpd_backend_probe: invalid bit pattern '" .. tostring(hex) .. "'")
	end
	digits = string.rep("0", 16 - #digits) .. digits
	local u = BitUnion()
	u.w[0] = tonumber(digits:sub(9, 16), 16)
	u.w[1] = tonumber(digits:sub(1, 8), 16)
	return u.d
end

local function parse_args(argv)
	local opts = {}
	local i = 1
	while i <= #argv do
		local a = argv[i]
		if a == "--detmath-root" or a == "--out" then
			i = i + 1
			opts[a:sub(3)] = argv[i]
		elseif a == "--help" or a == "-h" then
			opts.help = true
		else
			error("unknown argument: " .. tostring(a))
		end
		i = i + 1
	end
	return opts
end

local opts = parse_args(rawget(_G, "arg") or {})
if opts.help then
	io.write([[
Usage: luajit tools/wpd_backend_probe.lua --detmath-root DIR --out FILE
]])
	os.exit(0)
end
if not opts["detmath-root"] or not opts.out then
	io.stderr:write("wpd_backend_probe: --detmath-root and --out are required\n")
	os.exit(2)
end

package.path = opts["detmath-root"] .. "/?.lua;" ..
	opts["detmath-root"] .. "/?/init.lua;" .. package.path
local detmath = require("src.detmath")

-- Probe inputs (bit-exact) and the functions under test.
local PROBES = {
	{ name = "sin_25p7", fn = "sin", a = nil, value = 25.7 },
	{ name = "asin_hard", fn = "asin", a = "0xbfb97ca392b11d15" },
	{ name = "acos_hard", fn = "acos", a = "0x3feff49bfa1a7806" },
	{ name = "pow_neg_base_frac", fn = "pow", a = nil, value = -2.0, b = 3.7 },
}

local results = {}
local inputs = {}
for _, probe in ipairs(PROBES) do
	local a = probe.a ~= nil and double_of_bits(probe.a) or probe.value
	local r
	if probe.fn == "pow" then
		r = detmath.pow(a, probe.b)
	else
		r = detmath[probe.fn](a)
	end
	results[probe.name] = bits_hex(r)
	inputs[probe.name] = bits_hex(a)
end

local identity = detmath.identity()
local document = CanonicalJSON.object({
	format = "peggle.wpd_backend_probe",
	schema_version = 1,
	backend = detmath.backend,
	platform = identity.platform or "",
	library = identity.library or "",
	abi_version = identity.abi_version or 0,
	native_identity = identity.native_identity or "",
	inputs = CanonicalJSON.object(inputs),
	probes = CanonicalJSON.object(results),
})

local text = CanonicalJSON.encode(document) .. "\n"
local dir = opts.out:match("^(.*)/[^/]*$")
if dir and dir ~= "" then
	os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
end
local f, err = io.open(opts.out, "wb")
if not f then
	io.stderr:write("wpd_backend_probe: cannot write " .. opts.out .. ": " ..
		tostring(err) .. "\n")
	os.exit(3)
end
f:write(text)
f:close()
io.write("wpd_backend_probe: backend=", detmath.backend, " -> ", opts.out, "\n")
