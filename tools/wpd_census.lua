-- WP-D1: compute one backend's Lua results for the WP-D1 corpus.
--
-- Usage:
--   PEGGLE_MATH_BACKEND=core_math luajit tools/wpd_census.lua \
--     --detmath-root ../peggle_evolved \
--     --inputs tmp/core-math/wpd-inputs.json \
--     --out tmp/core-math/wpd-lua-core_math.json
--
-- Loads `src.detmath` from --detmath-root (the peggle_evolved development
-- tree), evaluates every input case through the selected backend, and writes
-- a canonical JSON document:
--
--   format          "peggle.wpd_math_results"
--   schema_version  1
--   backend         "system_libm" | "core_math"
--   identity        detmath.identity() (native_identity raw JSON when present)
--   inputs_sha256   SHA-256 of the inputs file bytes
--   results         parallel arrays per function
--   special_results array, same order as `special`
--   counts          per-function case counts
--
-- Unary functions go through detmath.<fn>; atan2/pow through
-- detmath.atan2/detmath.pow; `mod` through the plain Lua `%` operator
-- (numeric-contract section 9). All values are lowercase "0x%016x" strings.
--
-- The process exits nonzero when the requested backend is not the one
-- detmath selected, when the input document is malformed, or when the FFI
-- library cannot be loaded.

local ffi = require("ffi")

local script_dir = (arg[0] or "tools/wpd_census.lua"):match("^(.*)[/\\][^/\\]*$")
    or "."
local repo_root = script_dir .. "/.."

package.path = repo_root .. "/?.lua;" .. script_dir .. "/?.lua;" .. package.path

local SHA = require("tools.sha256")
local CanonicalJSON = dofile(script_dir .. "/canonical_json.lua")

-- ===========================================================================
-- IEEE-754 bit patterns
-- ===========================================================================

local BitUnion = ffi.typeof("union { double d; uint64_t u; }")

local function bits_hex(x)
    local u = BitUnion()
    u.d = x
    return string.format("0x%016x", u.u)
end

-- Parse "0x<16 hex digits>" without a double round-trip: build the uint64_t
-- from the text digit by digit so all 64 bits are preserved exactly.
local function parse_bit_hex(s)
    if type(s) ~= "string" then
        error("expected a bit-hex string, got " .. type(s), 3)
    end
    local hex = s:match("^0x(%x+)$")
    if hex == nil or #hex ~= 16 then
        error("malformed bit-hex value: " .. tostring(s), 3)
    end
    local u = 0ULL
    for i = 1, 16 do
        u = u * 16ULL + tonumber(hex:sub(i, i), 16)
    end
    local v = BitUnion()
    v.u = u
    return v.d
end

-- ===========================================================================
-- Argument parsing
-- ===========================================================================

local function parse_args(argv)
    local opts = {}
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--detmath-root" or a == "--inputs" or a == "--out" then
            i = i + 1
            if argv[i] == nil then error("missing value for " .. a, 2) end
            opts[a:sub(3)] = argv[i]
        elseif a == "--help" or a == "-h" then
            opts.help = true
        else
            error("unknown argument: " .. tostring(a), 2)
        end
        i = i + 1
    end
    return opts
end

local opts = parse_args(arg)
if opts.help then
    io.write([[
Usage: PEGGLE_MATH_BACKEND=<backend> luajit tools/wpd_census.lua \
  --detmath-root PATH --inputs PATH --out PATH
]])
    os.exit(0)
end
if not (opts["detmath-root"] and opts.inputs and opts.out) then
    io.stderr:write("wpd_census: --detmath-root, --inputs and --out are required\n")
    os.exit(2)
end

-- ===========================================================================
-- Load the backend
-- ===========================================================================

local detmath_root = opts["detmath-root"]
package.path = detmath_root .. "/?.lua;" .. package.path

local requested = os.getenv("PEGGLE_MATH_BACKEND")
if requested == nil or requested == "" then requested = "system_libm" end

local ok, detmath = pcall(require, "src.detmath")
if not ok then
    io.stderr:write("wpd_census: cannot load src.detmath from '"
        .. tostring(detmath_root) .. "': " .. tostring(detmath) .. "\n")
    os.exit(1)
end
if detmath.backend ~= requested then
    io.stderr:write("wpd_census: detmath selected backend '" .. tostring(detmath.backend)
        .. "' but PEGGLE_MATH_BACKEND requested '" .. requested .. "'\n")
    os.exit(1)
end

-- ===========================================================================
-- Inputs
-- ===========================================================================

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then error("cannot open " .. path .. ": " .. tostring(err), 2) end
    local data = f:read("*a")
    f:close()
    return data
end

local inputs_bytes = read_file(opts.inputs)
local inputs = CanonicalJSON.decode(inputs_bytes)
if inputs.format ~= "peggle.wpd_math_inputs" then
    error("unexpected inputs format: " .. tostring(inputs.format), 2)
end
if tonumber(inputs.schema_version) ~= 1 then
    error("unexpected inputs schema_version: " .. tostring(inputs.schema_version), 2)
end

-- ===========================================================================
-- Evaluation
-- ===========================================================================

local function call_function(fn, a, b)
    if fn == "mod" then
        return a % b
    end
    local f = detmath[fn]
    if f == nil then
        error("detmath has no function '" .. tostring(fn) .. "'", 2)
    end
    if b == nil then
        return f(a)
    end
    return f(a, b)
end

local function function_arity(fn)
    if fn == "atan2" or fn == "pow" or fn == "mod" then return 2 end
    return 1
end

local results = {}
local counts = {}
local total = 0

local function sections()
    local names = {}
    for name in pairs(inputs.cases) do names[#names + 1] = name end
    table.sort(names)
    return names
end

for _, name in ipairs(sections()) do
    local section = inputs.cases[name]
    local arity = tonumber(section.arity)
    if arity ~= function_arity(name) then
        error("arity mismatch for " .. name, 2)
    end
    local as = section.a or {}
    local bs = section.b
    if arity == 2 and (bs == nil or #bs ~= #as) then
        error("parallel array length mismatch for " .. name, 2)
    end
    local out = CanonicalJSON.array({})
    for i = 1, #as do
        local a = parse_bit_hex(as[i])
        local b = bs ~= nil and parse_bit_hex(bs[i]) or nil
        out[#out + 1] = bits_hex(call_function(name, a, b))
    end
    results[name] = out
    counts[name] = #as
    total = total + #as
end

local special_results = CanonicalJSON.array({})
local specials = inputs.special or {}
for i = 1, #specials do
    local spec = specials[i]
    if function_arity(spec.fn) == 2 and spec.b == nil then
        error("special " .. tostring(spec.name) .. " needs a second operand", 2)
    end
    if function_arity(spec.fn) == 1 and spec.b ~= nil then
        error("special " .. tostring(spec.name) .. " is unary but has b", 2)
    end
    local a = parse_bit_hex(spec.a)
    local b = spec.b ~= nil and parse_bit_hex(spec.b) or nil
    special_results[i] = CanonicalJSON.object({
        name = spec.name,
        result = bits_hex(call_function(spec.fn, a, b)),
    })
end

-- ===========================================================================
-- Identity and output
-- ===========================================================================

local identity = detmath.identity()
local identity_obj = CanonicalJSON.object({
    backend = identity.backend,
    platform = identity.platform,
    library = identity.library,
    abi_version = identity.abi_version,
    native_identity = identity.native_identity,
})

local document = CanonicalJSON.object({
    format = "peggle.wpd_math_results",
    schema_version = 1,
    backend = detmath.backend,
    identity = identity_obj,
    inputs_sha256 = SHA.sha256_hex(inputs_bytes),
    results = CanonicalJSON.object(results),
    special_results = special_results,
    counts = CanonicalJSON.object(counts),
})

local text = CanonicalJSON.encode(document) .. "\n"
local dir = opts.out:match("^(.*)/[^/]*$")
if dir then
    os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
end
local f, err = io.open(opts.out, "wb")
if not f then error("cannot write " .. opts.out .. ": " .. tostring(err), 2) end
f:write(text)
f:close()

io.write("wpd_census: backend=", detmath.backend,
    " functions=", #sections(),
    " cases=", total,
    " specials=", #specials,
    " out=", opts.out, "\n")
