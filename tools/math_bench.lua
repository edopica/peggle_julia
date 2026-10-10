-- WP-F on-host math microbenchmark (LuaJIT side).
--
-- Runs under plain LuaJIT against the peggle_evolved development tree
-- (--detmath-root) and measures every authoritative detmath function plus
-- Lua's floored modulo (`a % b`). Inputs are a fixed, precomputed table of
-- splitmix64-derived doubles (4096 entries: varied magnitudes and signs plus
-- hand-picked specials), so the JIT cannot constant-fold the calls. Every
-- function is warmed up (4096 calls, one full pass over the input table),
-- then timed in 21 fixed-size batches of 8192 calls. The output records raw
-- batch times, per-call nanoseconds (median/p90/p99), and a bit-exact XOR
-- checksum of the results, so identical reruns can be proven to compute the
-- same values.
--
-- The same generator and schedule are implemented in
-- julia/PeggleSim/bin/math_bench.jl; both engines emit the same
-- inputs_checksum but their absolute per-call costs are separate
-- measurements.
--
-- Usage:
--   PEGGLE_MATH_BACKEND=core_math PEGGLE_MATH_LIB=/path/libpeggle_math.so \
--     luajit tools/math_bench.lua --detmath-root ../peggle_evolved \
--     --out tmp/core-math/perf/math-bench-lua-core_math.json

local script_dir = (debug.getinfo(1, "S").source:match("@(.*)/[^/]*$")) or "."
package.path = script_dir .. "/?.lua;" .. package.path

local ffi = require("ffi")
local bit = require("bit")
local CanonicalJSON = require("canonical_json")

ffi.cdef [[
	typedef struct { int64_t tv_sec; int64_t tv_nsec; } peggle_bench_timespec;
	int clock_gettime(int clk_id, peggle_bench_timespec *tp);
]]

local U64 = ffi.typeof("union { uint64_t u; uint32_t w[2]; }")
local BitUnion = ffi.typeof("union { double d; uint64_t u; uint32_t w[2]; }")

local N_INPUTS = 4096
local WARMUP_CALLS = 4096
local CALLS_PER_BATCH = 8192
local BATCH_COUNT = 21
local CLOCK_MONOTONIC = 1

local function parse_args(argv)
	local opts = { ["detmath-root"] = "../peggle_evolved" }
	local i = 1
	while i <= #argv do
		local a = argv[i]
		if a == "--detmath-root" or a == "--out" then
			i = i + 1
			if i > #argv then error("missing value for " .. a) end
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
Usage: luajit tools/math_bench.lua [--detmath-root DIR] --out FILE

  --detmath-root DIR  peggle_evolved development tree (default ../peggle_evolved)
  --out FILE          JSON output path (required)

Environment: PEGGLE_MATH_BACKEND selects the backend; PEGGLE_MATH_LIB points
at the core_math shared library.
]])
	os.exit(0)
end
if not opts.out then
	io.stderr:write("math_bench: --out is required\n")
	os.exit(2)
end

package.path = opts["detmath-root"] .. "/?.lua;" ..
	opts["detmath-root"] .. "/?/init.lua;" .. package.path
local detmath = require("src.detmath")

-- ---------------------------------------------------------------------------
-- Clock
-- ---------------------------------------------------------------------------
local ts = ffi.new("peggle_bench_timespec")

local function now_ns()
	ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
	return tonumber(ts.tv_sec) * 1e9 + tonumber(ts.tv_nsec)
end

-- ---------------------------------------------------------------------------
-- splitmix64 (64-bit state carried in an FFI union; all hosts in the support
-- matrix are little-endian, so w[0] is the low word)
-- ---------------------------------------------------------------------------
local function xor_shift_right_words(u, n)
	local hi, lo = u.w[1], u.w[0]
	local sh_hi, sh_lo
	if n < 32 then
		sh_hi = bit.rshift(hi, n)
		sh_lo = bit.bor(bit.rshift(lo, n), bit.lshift(hi, 32 - n))
	else
		sh_hi = 0
		sh_lo = bit.rshift(hi, n - 32)
	end
	u.w[0] = bit.bxor(lo, sh_lo)
	u.w[1] = bit.bxor(hi, sh_hi)
end

local rng = U64()
rng.u = 0x9E3779B97F4A7C15ULL

local function next_u64()
	rng.u = rng.u + 0x9E3779B97F4A7C15ULL
	local z = U64()
	z.u = rng.u
	xor_shift_right_words(z, 30)
	z.u = z.u * 0xBF58476D1CE4E5B9ULL
	xor_shift_right_words(z, 27)
	z.u = z.u * 0x94D049BB133111EBULL
	xor_shift_right_words(z, 31)
	return z
end

-- Top 53 bits as a double in [0, 1); exact in both engines.
local function next_unit()
	local z = next_u64()
	return (z.w[1] * 2097152.0 + bit.rshift(z.w[0], 11)) / 9007199254740992.0
end

-- ---------------------------------------------------------------------------
-- Input tables (identical generation order in the Julia benchmark)
-- ---------------------------------------------------------------------------
local pow2 = {}
pow2[0] = 1.0
for e = 1, 12 do pow2[e] = pow2[e - 1] * 2.0 end
for e = -1, -12, -1 do pow2[e] = pow2[e + 1] * 0.5 end

local inputs = {}
for i = 1, N_INPUTS do
	local e = math.floor(next_unit() * 25.0) - 12
	local s = next_unit()
	inputs[i] = (2.0 * s - 1.0) * pow2[e]
end
inputs[1] = 0.0
inputs[2] = -0.0
inputs[3] = 0.5
inputs[4] = -0.5
inputs[5] = 1.0
inputs[6] = -1.0
inputs[7] = 3.141592653589793
inputs[8] = -3.141592653589793
inputs[9] = 1e9
inputs[10] = -1e9
inputs[11] = 1e-9
inputs[12] = -1e-9

local unit_in = {}
local exp_in = {}
local log_in = {}
local pow_b = {}
for i = 1, N_INPUTS do
	unit_in[i] = 2.0 * next_unit() - 1.0
end
for i = 1, N_INPUTS do
	exp_in[i] = 40.0 * next_unit() - 20.0
end
for i = 1, N_INPUTS do
	local e = math.floor(next_unit() * 19.0) - 9
	log_in[i] = pow2[e] * (1.0 + next_unit())
end
for i = 1, N_INPUTS do
	pow_b[i] = 6.0 * next_unit() - 3.0
end

local sqrt_in = {}
local atan2_x = {}
local mod_b = {}
for i = 1, N_INPUTS do
	sqrt_in[i] = math.abs(inputs[i])
	atan2_x[i] = inputs[(i * 7 + 3) % N_INPUTS + 1]
	local b = inputs[(i * 13 + 5) % N_INPUTS + 1]
	if b == 0.0 or b ~= b then b = 1.5 end
	mod_b[i] = b
end

-- XOR of the IEEE-754 bits of every generated input, in generation order.
-- Both engines must report the same value.
local input_acc = BitUnion()
input_acc.u = 0
local function mix_input(x)
	local u = BitUnion()
	u.d = x
	input_acc.w[0] = bit.bxor(input_acc.w[0], u.w[0])
	input_acc.w[1] = bit.bxor(input_acc.w[1], u.w[1])
end
for i = 1, N_INPUTS do mix_input(inputs[i]) end
for i = 1, N_INPUTS do mix_input(unit_in[i]) end
for i = 1, N_INPUTS do mix_input(exp_in[i]) end
for i = 1, N_INPUTS do mix_input(log_in[i]) end
for i = 1, N_INPUTS do mix_input(pow_b[i]) end
local inputs_checksum = string.format("0x%08x%08x", input_acc.w[1], input_acc.w[0])

-- ---------------------------------------------------------------------------
-- Measurement
-- ---------------------------------------------------------------------------
local function percentile(sorted, q)
	local n = #sorted
	if n == 0 then return 0.0 end
	local idx = math.ceil(q * n)
	if idx < 1 then idx = 1 end
	if idx > n then idx = n end
	return sorted[idx]
end

local state = { sink = 0.0 }

local function bench_unary(fn, xs)
	local n = #xs
	local acc = BitUnion()
	acc.u = 0
	local warm_sink = 0.0
	for k = 0, WARMUP_CALLS - 1 do
		local y = fn(xs[k % n + 1])
		local u = BitUnion()
		u.d = y
		acc.w[0] = bit.bxor(acc.w[0], u.w[0])
		acc.w[1] = bit.bxor(acc.w[1], u.w[1])
		warm_sink = warm_sink + y
	end
	local batches = {}
	local percall = {}
	local total_ns = 0
	local sink = 0.0
	for b = 1, BATCH_COUNT do
		local t0 = now_ns()
		local k = 0
		while k < CALLS_PER_BATCH do
			sink = sink + fn(xs[k % n + 1])
			k = k + 1
		end
		local elapsed = now_ns() - t0
		batches[b] = elapsed
		percall[b] = elapsed / CALLS_PER_BATCH
		total_ns = total_ns + elapsed
	end
	state.sink = state.sink + warm_sink + sink
	table.sort(percall)
	return {
		batches = batches,
		percall = percall,
		checksum = string.format("0x%08x%08x", acc.w[1], acc.w[0]),
		total_ns = total_ns,
	}
end

local function bench_binary(fn, xs, ys)
	local n = #xs
	local acc = BitUnion()
	acc.u = 0
	local warm_sink = 0.0
	for k = 0, WARMUP_CALLS - 1 do
		local i = k % n + 1
		local y = fn(xs[i], ys[i])
		local u = BitUnion()
		u.d = y
		acc.w[0] = bit.bxor(acc.w[0], u.w[0])
		acc.w[1] = bit.bxor(acc.w[1], u.w[1])
		warm_sink = warm_sink + y
	end
	local batches = {}
	local percall = {}
	local total_ns = 0
	local sink = 0.0
	for b = 1, BATCH_COUNT do
		local t0 = now_ns()
		local k = 0
		while k < CALLS_PER_BATCH do
			local i = k % n + 1
			sink = sink + fn(xs[i], ys[i])
			k = k + 1
		end
		local elapsed = now_ns() - t0
		batches[b] = elapsed
		percall[b] = elapsed / CALLS_PER_BATCH
		total_ns = total_ns + elapsed
	end
	state.sink = state.sink + warm_sink + sink
	table.sort(percall)
	return {
		batches = batches,
		percall = percall,
		checksum = string.format("0x%08x%08x", acc.w[1], acc.w[0]),
		total_ns = total_ns,
	}
end

local SPECS = {
	{ name = "sin", arity = 1, fn = detmath.sin, xs = inputs },
	{ name = "cos", arity = 1, fn = detmath.cos, xs = inputs },
	{ name = "tan", arity = 1, fn = detmath.tan, xs = inputs },
	{ name = "asin", arity = 1, fn = detmath.asin, xs = unit_in },
	{ name = "acos", arity = 1, fn = detmath.acos, xs = unit_in },
	{ name = "atan", arity = 1, fn = detmath.atan, xs = inputs },
	{ name = "atan2", arity = 2, fn = detmath.atan2, xs = inputs, ys = atan2_x },
	{ name = "exp", arity = 1, fn = detmath.exp, xs = exp_in },
	{ name = "log", arity = 1, fn = detmath.log, xs = log_in },
	{ name = "pow", arity = 2, fn = detmath.pow, xs = inputs, ys = pow_b },
	{ name = "sqrt", arity = 1, fn = detmath.sqrt, xs = sqrt_in },
	{ name = "mod", arity = 2, fn = function(a, b) return a % b end,
		xs = inputs, ys = mod_b },
}

local per_function = {}
local total_seconds = 0.0
for _, spec in ipairs(SPECS) do
	local result
	if spec.arity == 1 then
		result = bench_unary(spec.fn, spec.xs)
	else
		result = bench_binary(spec.fn, spec.xs, spec.ys)
	end
	per_function[spec.name] = CanonicalJSON.object({
		ns_per_call = CanonicalJSON.object({
			median = percentile(result.percall, 0.50),
			p90 = percentile(result.percall, 0.90),
			p99 = percentile(result.percall, 0.99),
		}),
		batches = CanonicalJSON.array(result.batches),
		checksum = result.checksum,
		calls = BATCH_COUNT * CALLS_PER_BATCH,
		total_seconds = result.total_ns / 1e9,
	})
	total_seconds = total_seconds + result.total_ns / 1e9
	io.write(string.format("%-5s median=%10.3f ns/call  checksum=%s\n",
		spec.name,
		per_function[spec.name].ns_per_call.median,
		result.checksum))
end

local identity = detmath.identity()
local identity_obj = {
	backend = identity.backend,
	platform = identity.platform or "",
	abi_version = identity.abi_version or 0,
}
if identity.library then identity_obj.library = identity.library end
if identity.native_identity then identity_obj.native_identity = identity.native_identity end

local document = CanonicalJSON.object({
	format = "peggle.math_bench",
	schema_version = 1,
	engine = "luajit",
	backend = detmath.backend,
	identity = CanonicalJSON.object(identity_obj),
	input_count = N_INPUTS,
	inputs_checksum = inputs_checksum,
	warmup_calls = WARMUP_CALLS,
	calls_per_batch = CALLS_PER_BATCH,
	batch_count = BATCH_COUNT,
	measured_calls_per_function = BATCH_COUNT * CALLS_PER_BATCH,
	total_seconds = total_seconds,
	per_function = CanonicalJSON.object(per_function),
})

local dir = opts.out:match("^(.*)/[^/]*$")
if dir and dir ~= "" then
	os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
end
local f, err = io.open(opts.out, "wb")
if not f then
	io.stderr:write("math_bench: cannot write " .. opts.out .. ": " ..
		tostring(err) .. "\n")
	os.exit(3)
end
f:write(CanonicalJSON.encode(document) .. "\n")
f:close()

-- The sink consumes every measured result (sum) so dead-code elimination
-- cannot erase the benchmarked calls.
io.write(string.format("math_bench: engine=luajit backend=%s sink=%.17g\n",
	detmath.backend, state.sink))
io.write("math_bench: wrote " .. opts.out .. "\n")
