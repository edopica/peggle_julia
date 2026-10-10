-- Capture the cross-language math census fixture.
--
-- Runs under plain `luajit` (no LÖVE, no display): LuaJIT's math.* functions
-- call the system libm / libc directly, which is exactly the implementation
-- the reference game uses. Every expected value is captured as the 64-bit
-- IEEE-754 bit pattern using LuaJIT FFI, never as a decimal string.
--
-- Input corpus
-- ------------
-- Every finite double recorded in `fixtures/expected/*.json` and
-- `interchange/levels/*.v1.json` (canonical JSON, read with
-- tools/canonical_json.lua), deduplicated bit-exactly via an FFI union and
-- sorted by numeric value (bit pattern breaks -0/+0 and any other exact
-- ties). The sorted list is "recorded".
--
-- Recorded-input contribution caps
-- --------------------------------
-- To keep the fixture bounded, each function uses at most
-- MAX_RECORDED_VALUES recorded inputs (unary functions) and at most
-- MAX_RECORDED_PAIRS recorded input pairs (binary functions). When the
-- corpus is larger, a deterministic even-stride decimation that preserves
-- the first and last elements is applied. The current corpus (1546 unique
-- values from 33 files) is below both caps; the caps only guard growth.
--
-- Input sets per function (minimums from tmp/m2/INTERFACES.md):
--   sin, cos, atan   : trig boundaries + all recorded values
--   atan2            : axis/quadrant/sign pairs, equal magnitudes, tiny and
--                      huge ratios, explicit boundary values, plus two
--                      deterministic recorded pairings (cyclic successor and
--                      reverse mirror)
--   asin             : -1, +1, one ULP inside and one ULP outside both ends,
--                      small magnitudes, recorded values in [-1, 1]
--   pow              : explicit bases x explicit exponents, plus recorded
--                      bases paired with a cycling explicit exponent
--   mod              : sign combinations, near-multiples, zero/tiny/huge
--                      operands, plus deterministic recorded pairs. Pairs
--                      whose Lua result is NaN or infinite are excluded
--                      (canonical JSON rejects non-finite numbers).
--   exp, log, sqrt   : boundary values and recorded values in the function
--                      domain (exp: all reals; log: positives plus +-0;
--                      sqrt: nonnegative)
--
-- Expected values that are themselves non-finite (NaN / +-Inf, e.g. asin
-- outside [-1, 1] or pow overflow) are still encoded as bit patterns; the
-- canonical encoder only rejects raw JSON numbers, so the strings are safe.
--
-- source block
-- ------------
--   reference_revision / reference_tree / config_sha256 : passed by
--       scripts/capture_math_census.sh, discovered exactly like
--       scripts/capture_fixtures.sh does.
--   fixtures_sha256 : SHA-256 of the harvested corpus listing, defined as
--       sha256 over the concatenation, in ascending path order, of
--           "<relative path>\0<sha256 of file bytes>\n"
--       for every fixture/level file that contributed recorded numbers.
--       This pins the input corpus without depending on the working dir.
--
-- Usage:
--   luajit tools/capture_math_census.lua \
--       --reference-revision REV --reference-tree TREE --config-sha256 SHA \
--       [--out PATH] [--check]
--   --check recomputes and byte-compares with the committed fixture and
--   never writes it.

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
double nextafter(double, double);
]]

local script_dir = (arg[0] or "tools/capture_math_census.lua"):match("^(.*)[/\\][^/\\]*$")
    or "."
local repo_root = script_dir .. "/.."
local CanonicalJSON = dofile(script_dir .. "/canonical_json.lua")

-- ===========================================================================
-- SHA-256 (pure LuaJIT; used for the corpus provenance hash)
-- ===========================================================================

local SHA256_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256_hex(message)
    local band, bxor, bnot, ror, rshift = bit.band, bit.bxor, bit.bnot, bit.ror, bit.rshift
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local len = #message
    local bitlen = len * 8
    local zeros = (56 - ((len + 1) % 64)) % 64
    local hi = math.floor(bitlen / 4294967296) % 4294967296
    local lo = bitlen % 4294967296
    local msg = message .. "\128" .. string.rep("\0", zeros)
        .. string.char(
            math.floor(hi / 16777216) % 256, math.floor(hi / 65536) % 256,
            math.floor(hi / 256) % 256, hi % 256,
            math.floor(lo / 16777216) % 256, math.floor(lo / 65536) % 256,
            math.floor(lo / 256) % 256, lo % 256)

    local w = {}
    local blocks = #msg / 64
    for block = 0, blocks - 1 do
        local base = block * 64
        for j = 0, 15 do
            local o = base + j * 4 + 1
            local b0, b1, b2, b3 = msg:byte(o, o + 3)
            w[j] = b0 * 16777216 + b1 * 65536 + b2 * 256 + b3
        end
        for j = 16, 63 do
            local x, y = w[j - 15], w[j - 2]
            local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
            local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
            w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % 4294967296
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for j = 0, 63 do
            local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = (h + s1 + ch + SHA256_K[j + 1] + w[j]) % 4294967296
            local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = (s0 + maj) % 4294967296
            h = g
            g = f
            f = e
            e = (d + temp1) % 4294967296
            d = c
            c = b
            b = a
            a = (temp1 + temp2) % 4294967296
        end
        h0 = (h0 + a) % 4294967296
        h1 = (h1 + b) % 4294967296
        h2 = (h2 + c) % 4294967296
        h3 = (h3 + d) % 4294967296
        h4 = (h4 + e) % 4294967296
        h5 = (h5 + f) % 4294967296
        h6 = (h6 + g) % 4294967296
        h7 = (h7 + h) % 4294967296
    end

    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        h0, h1, h2, h3, h4, h5, h6, h7)
end

-- ===========================================================================
-- IEEE-754 bit patterns
-- ===========================================================================

local BitUnion = ffi.typeof("union { double d; uint64_t u; }")

local function bits_of(x)
    local u = BitUnion()
    u.d = x
    return u.u
end

local function bits_hex(x)
    local u = BitUnion()
    u.d = x
    return string.format("0x%016x", u.u)
end

local function double_of_bits(u)
    local v = BitUnion()
    v.u = u
    return v.d
end

local function ulp_up(x) return ffi.C.nextafter(x, math.huge) end
local function ulp_down(x) return ffi.C.nextafter(x, -math.huge) end

-- ===========================================================================
-- File discovery / corpus loading
-- ===========================================================================

local function shell_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then error("cannot open " .. path .. ": " .. tostring(err), 2) end
    local data = f:read("*a")
    f:close()
    return data
end

local function list_files(dir, suffix)
    local files = {}
    local cmd = "LC_ALL=C ls -1 " .. shell_quote(dir)
        .. " 2>/dev/null | LC_ALL=C sort"
    local pipe = io.popen(cmd)
    if not pipe then error("cannot list " .. dir, 2) end
    for line in pipe:lines() do
        if line:sub(-#suffix) == suffix then
            files[#files + 1] = dir .. "/" .. line
        end
    end
    pipe:close()
    return files
end

local function walk_numbers(value, out)
    local t = type(value)
    if t == "number" then
        if value == value and value ~= math.huge and value ~= -math.huge then
            out[#out + 1] = value
        end
    elseif t == "table" then
        for _, v in pairs(value) do
            walk_numbers(v, out)
        end
    end
end

local function collect_recorded()
    local expected_files = list_files(repo_root .. "/fixtures/expected", ".json")
    local level_files = list_files(repo_root .. "/interchange/levels", ".v1.json")
    if #level_files == 0 then
        error("no interchange level artifacts under interchange/levels; "
            .. "run scripts/export_interchange.sh first", 2)
    end
    local files = {}
    local function add(fs)
        for _, f in ipairs(fs) do files[#files + 1] = f end
    end
    add(expected_files)
    add(level_files)

    local hash_lines = {}
    local unique = {}
    local seen = {}
    for _, path in ipairs(files) do
        local data = read_file(path)
        local rel = path
        local prefix = repo_root .. "/"
        if rel:sub(1, #prefix) == prefix then
            rel = rel:sub(#prefix + 1)
        end
        hash_lines[#hash_lines + 1] = rel .. "\0" .. sha256_hex(data) .. "\n"
        local decoded = CanonicalJSON.decode_file(path)
        local values = {}
        walk_numbers(decoded, values)
        for _, v in ipairs(values) do
            local key = bits_hex(v)
            if not seen[key] then
                seen[key] = true
                unique[#unique + 1] = v
            end
        end
    end

    table.sort(unique, function(a, b)
        if a < b then return true end
        if a > b then return false end
        return bits_of(a) < bits_of(b)
    end)

    return unique, sha256_hex(table.concat(hash_lines))
end

-- ===========================================================================
-- Input construction helpers
-- ===========================================================================

local MAX_RECORDED_VALUES = 8192
local MAX_RECORDED_PAIRS = 8192

local function cap_values(values, limit)
    if #values <= limit then return values end
    local out = {}
    local n = #values
    for i = 1, limit do
        local idx = math.floor((i - 1) * (n - 1) / (limit - 1) + 0.5) + 1
        out[#out + 1] = values[idx]
    end
    return out
end

local function cap_pairs(pairs, limit)
    if #pairs <= limit then return pairs end
    return cap_values(pairs, limit)
end

local function unique_values(values)
    local seen, out = {}, {}
    for _, x in ipairs(values) do
        local k = bits_hex(x)
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = x
        end
    end
    return out
end

local function unique_pairs(pairs)
    local seen, out = {}, {}
    for _, pair in ipairs(pairs) do
        local k = bits_hex(pair[1]) .. ":" .. bits_hex(pair[2])
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = pair
        end
    end
    return out
end

local function filter_values(values, predicate)
    local out = {}
    for _, x in ipairs(values) do
        if predicate(x) then out[#out + 1] = x end
    end
    return out
end

local function append(values, extra)
    local out = {}
    for _, x in ipairs(values) do out[#out + 1] = x end
    for _, x in ipairs(extra) do out[#out + 1] = x end
    return out
end

-- Explicit boundary cases ---------------------------------------------------

local function trig_boundaries()
    local b = {}
    local function add(x) b[#b + 1] = x end
    add(0.0)
    add(-0.0)
    add(1.0)
    add(-1.0)
    add(5e-324)
    add(-5e-324)
    add(1e-300)
    add(-1e-300)
    add(1e300)
    add(-1e300)
    add(math.pi)
    add(-math.pi)
    add(math.pi / 2)
    add(-math.pi / 2)
    for k = -3, 3 do
        local v = k * math.pi
        add(ulp_down(v))
        add(v)
        add(ulp_up(v))
    end
    for k = -5, 5 do
        local v = k * (math.pi / 2)
        add(ulp_down(v))
        add(v)
        add(ulp_up(v))
    end
    return b
end

local function atan2_boundary_pairs()
    local p = {}
    local function add(y, x) p[#p + 1] = { y, x } end
    local zeros = { 0.0, -0.0 }
    local ones = { 1.0, -1.0 }
    local tiny = { 5e-324, -5e-324, 1e-300, -1e-300 }
    local huge = { 1e300, -1e300 }
    -- axes and quadrants
    for _, y in ipairs(zeros) do
        for _, x in ipairs(zeros) do add(y, x) end
    end
    for _, s in ipairs(ones) do
        add(s, 0.0)
        add(0.0, s)
        add(s, s)
        add(s, -s)
        add(-0.0, s)
        add(s, -0.0)
    end
    -- equal magnitudes, tiny and huge ratios
    for _, m in ipairs({ 1.0, -1.0, 0.5, -0.5, 5e-324, -5e-324, 1e-300, -1e-300, 1e300, -1e300 }) do
        add(m, m)
        add(m, -m)
        add(m, 1.0)
        add(1.0, m)
    end
    for _, y in ipairs(tiny) do
        for _, x in ipairs(huge) do
            add(y, x)
            add(x, y)
        end
        add(y, 5e-324)
        add(y, -5e-324)
        add(y, 1e-300)
        add(y, -1e-300)
        add(y, 1.0)
    end
    for _, y in ipairs(huge) do
        add(y, 5e-324)
        add(y, -5e-324)
        add(y, 1e-300)
        add(y, -1e-300)
        add(y, 1.0)
    end
    return p
end

local function asin_boundaries()
    return {
        0.0, -0.0, 1.0, -1.0,
        ulp_down(1.0), ulp_up(-1.0),
        ulp_up(1.0), ulp_down(-1.0),
        0.5, -0.5, 1e-300, -1e-300, 5e-324, -5e-324,
        math.pi / 2, -math.pi / 2,
    }
end

local POW_BASES = { 0.0, -0.0, 1.0, -1.0, 2.0, 0.5, -2.0, 1e300, 5e-324 }
local POW_EXPONENTS = { 0.0, 0.5, 1.0, 2.0, -1.0, -0.5, 3.7, 1e300 }

local function pow_boundary_pairs()
    local p = {}
    for _, a in ipairs(POW_BASES) do
        for _, b in ipairs(POW_EXPONENTS) do
            p[#p + 1] = { a, b }
        end
    end
    return p
end

local function mod_boundary_pairs()
    local p = {}
    local function add(a, b) p[#p + 1] = { a, b } end
    local divisors = { 1.0, -1.0, 3.0, -3.0, 0.5, -0.5, 2.0, -2.0, math.pi, -math.pi }
    for _, b in ipairs(divisors) do
        for k = -2, 2 do
            local v = k * b
            add(v, b)
            add(v + b * 0.25, b)
            add(v - b * 0.25, b)
            add(ulp_up(v), b)
            add(ulp_down(v), b)
        end
    end
    -- zero and sign handling
    for _, a in ipairs({ 0.0, -0.0, 1.0, -1.0, 5.5, -5.5, 7.0, -7.0 }) do
        add(a, 5.0)
        add(a, -5.0)
        add(a, 1.5)
        add(a, -1.5)
    end
    -- tiny / huge operands and ratios
    local extremes = { 5e-324, -5e-324, 1e-300, -1e-300, 1e300, -1e300 }
    for _, a in ipairs(extremes) do
        for _, b in ipairs({ 1.0, -1.0, 3.0, -3.0, 5e-324, 1e-300, 1e300 }) do
            add(a, b)
        end
    end
    return p
end

local function exp_boundaries()
    return {
        0.0, -0.0, 5e-324, -5e-324, 1e-300, -1e-300,
        1.0, -1.0, 0.5, -0.5,
        709.0, 710.0, -745.0, -746.0,
        math.pi, -math.pi, 1e300, -1e300,
    }
end

local function log_boundaries()
    return {
        0.0, -0.0, 5e-324, 1e-300, 2.2250738585072014e-308,
        0.5, 1.0, math.exp(1.0), 2.0, math.pi, 10.0, 1e300,
    }
end

local function sqrt_boundaries()
    return {
        0.0, -0.0, 5e-324, 1e-300, 2.2250738585072014e-308,
        0.25, 0.5, 1.0, 2.0, math.pi, 1e300,
    }
end

-- Recorded pairings ---------------------------------------------------------

local function cyclic_pairs(recorded, limit)
    local pairs = {}
    local n = #recorded
    for i = 1, n do
        pairs[#pairs + 1] = { recorded[i], recorded[(i % n) + 1] }
        if #pairs >= limit then break end
    end
    return pairs
end

local function mirror_pairs(recorded, limit)
    local pairs = {}
    local n = #recorded
    for i = 1, n do
        pairs[#pairs + 1] = { recorded[i], recorded[n + 1 - i] }
        if #pairs >= limit then break end
    end
    return pairs
end

-- ===========================================================================
-- Argument parsing
-- ===========================================================================

local function parse_args(argv)
    local opts = { check = false }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--out" then
            i = i + 1
            opts.out = argv[i]
        elseif a == "--check" then
            opts.check = true
        elseif a == "--reference-revision" then
            i = i + 1
            opts.revision = argv[i]
        elseif a == "--reference-tree" then
            i = i + 1
            opts.tree = argv[i]
        elseif a == "--config-sha256" then
            i = i + 1
            opts.config_sha = argv[i]
        elseif a == "--help" or a == "-h" then
            opts.help = true
        else
            error("unknown argument: " .. tostring(a))
        end
        i = i + 1
    end
    return opts
end

local opts = parse_args(arg)
if opts.help then
    io.write([[
Usage: luajit tools/capture_math_census.lua \
  --reference-revision REV --reference-tree TREE --config-sha256 SHA \
  [--out PATH] [--check]

Captures fixtures/math_census/math_census.v1.json from the LuaJIT system
libm. --check recomputes and byte-compares without writing.
]])
    os.exit(0)
end
if not (opts.revision and opts.tree and opts.config_sha) then
    io.stderr:write("capture_math_census: --reference-revision, --reference-tree "
        .. "and --config-sha256 are required; use scripts/capture_math_census.sh\n")
    os.exit(2)
end
opts.out = opts.out or (repo_root .. "/fixtures/math_census/math_census.v1.json")

-- ===========================================================================
-- Build the census
-- ===========================================================================

local recorded, fixtures_sha = collect_recorded()

local function recorded_values()
    return cap_values(recorded, MAX_RECORDED_VALUES)
end

local function recorded_pairs(limit)
    return cap_pairs(cyclic_pairs(recorded, limit), limit)
end

local inputs = {}
local expected = {}
local counts = {}

local function add_unary(name, input_list, fn)
    local list = unique_values(input_list)
    local exp = {}
    for i = 1, #list do
        exp[i] = bits_hex(fn(list[i]))
    end
    inputs[name] = list
    expected[name] = exp
    counts[name] = #list
end

local function add_binary(name, a_key, b_key, pairs, fn, keep)
    local list = unique_pairs(pairs)
    local a, b, exp = {}, {}, {}
    for i = 1, #list do
        local r = fn(list[i][1], list[i][2])
        if keep == nil or keep(r) then
            a[#a + 1] = list[i][1]
            b[#b + 1] = list[i][2]
            exp[#exp + 1] = bits_hex(r)
        end
    end
    inputs[a_key] = a
    inputs[b_key] = b
    expected[name] = exp
    counts[name] = #exp
end

local trig = append(trig_boundaries(), recorded_values())

add_unary("sin", trig, math.sin)
add_unary("cos", trig, math.cos)
add_unary("atan", trig, math.atan)

local atan2_recorded = cap_pairs(
    append(cyclic_pairs(recorded, MAX_RECORDED_PAIRS),
        mirror_pairs(recorded, MAX_RECORDED_PAIRS)),
    MAX_RECORDED_PAIRS)
local atan2_pairs = append(atan2_boundary_pairs(), atan2_recorded)
add_binary("atan2", "atan2_y", "atan2_x", atan2_pairs, math.atan2)

local asin_inputs = append(asin_boundaries(),
    filter_values(recorded_values(), function(x) return math.abs(x) <= 1.0 end))
add_unary("asin", asin_inputs, math.asin)

local pow_recorded = {}
for i = 1, #recorded do
    pow_recorded[#pow_recorded + 1] = { recorded[i], POW_EXPONENTS[((i - 1) % #POW_EXPONENTS) + 1] }
end
local pow_pairs = append(pow_boundary_pairs(), cap_pairs(pow_recorded, MAX_RECORDED_PAIRS))
add_binary("pow", "pow_a", "pow_b", pow_pairs, function(a, b) return a ^ b end)

local function finite(r) return r == r and r ~= math.huge and r ~= -math.huge end

local mod_pairs = append(mod_boundary_pairs(), recorded_pairs(MAX_RECORDED_PAIRS))
add_binary("mod", "mod_a", "mod_b", mod_pairs, function(a, b) return a % b end, finite)

add_unary("exp", append(exp_boundaries(), recorded_values()), math.exp)
add_unary("log", append(log_boundaries(),
    filter_values(recorded_values(), function(x) return x > 0.0 end)), math.log)
add_unary("sqrt", append(sqrt_boundaries(),
    filter_values(recorded_values(), function(x) return x >= 0.0 end)), math.sqrt)

-- ===========================================================================
-- Encode and write / check
-- ===========================================================================

local function array_of(list)
    return CanonicalJSON.array(list)
end

local function object_of(map)
    return CanonicalJSON.object(map)
end

local input_arrays = {}
for k, v in pairs(inputs) do input_arrays[k] = array_of(v) end
local expected_arrays = {}
for k, v in pairs(expected) do expected_arrays[k] = array_of(v) end

local document = object_of({
    format = "peggle.math_census",
    schema_version = 1,
    source = object_of({
        reference_revision = opts.revision,
        reference_tree = opts.tree,
        config_sha256 = opts.config_sha,
        fixtures_sha256 = fixtures_sha,
    }),
    counts = object_of(counts),
    inputs = object_of(input_arrays),
    expected = object_of(expected_arrays),
})

local text = CanonicalJSON.encode(document) .. "\n"

if opts.check then
    local committed = read_file(opts.out)
    if committed == text then
        io.write("math census check OK: ", opts.out, " (", #text, " bytes)\n")
        os.exit(0)
    end
    local first = 1
    local limit = math.min(#committed, #text)
    while first <= limit and committed:byte(first) == text:byte(first) do
        first = first + 1
    end
    io.stderr:write(string.format(
        "math census check FAILED: %s differs at byte %d "
            .. "(committed %d bytes, recomputed %d bytes)\n",
        opts.out, first, #committed, #text))
    os.exit(1)
end

local dir = opts.out:match("^(.*)/[^/]*$")
if dir then
    os.execute("mkdir -p " .. shell_quote(dir))
end
local f, err = io.open(opts.out, "wb")
if not f then error("cannot write " .. opts.out .. ": " .. tostring(err), 2) end
f:write(text)
f:close()
io.write("wrote ", opts.out, " (", #text, " bytes, fixtures_sha256=", fixtures_sha, ")\n")
