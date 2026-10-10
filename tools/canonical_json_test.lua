-- Unit tests for the canonical JSON codec. Plain LuaJIT; no LOVE.
--
-- Run: luajit tools/canonical_json_test.lua

local this = debug.getinfo(1, "S").source:sub(2)
local dir = this:match("^(.*)[/\\]") or "."
package.path = dir .. "/?.lua;" .. package.path

local CanonicalJSON = require("canonical_json")

local passed = 0

local function eq(got, want, label)
	if got ~= want then
		error(string.format("FAIL %s\n  got:  %s\n  want: %s",
			label, tostring(got), tostring(want)), 2)
	end
	passed = passed + 1
end

local function ok(cond, label)
	if not cond then error("FAIL " .. label, 2) end
	passed = passed + 1
end

local encode = CanonicalJSON.encode
local decode = CanonicalJSON.decode
local array = CanonicalJSON.array
local object = CanonicalJSON.object

-- Explicit empty containers.
eq(encode(object({})), "{}", "object({}) encodes as {}")
eq(encode(array({})), "[]", "array({}) encodes as []")

-- Decoding preserves container kind.
eq(encode(decode("{}")), "{}", "decode('{}') re-encodes as {}")
eq(encode(decode("[]")), "[]", "decode('[]') re-encodes as []")

-- kind helper.
eq(CanonicalJSON.kind(object({})), "object", "kind of marked object")
eq(CanonicalJSON.kind(array({})), "array", "kind of marked array")
eq(CanonicalJSON.kind({}), nil, "kind of unmarked table")
eq(CanonicalJSON.kind({ 1 }), nil, "kind of unmarked non-empty table")
eq(CanonicalJSON.kind(decode("{}")), "object", "kind of decoded object")
eq(CanonicalJSON.kind(decode("[]")), "array", "kind of decoded array")

-- Nested document mixing empty/non-empty containers, byte-for-byte.
local doc = '{"a":{},"b":[],"c":{"d":[1,2],"e":{}}}'
eq(encode(decode(doc)), doc, "nested document round-trips exactly")

-- Marked containers track later mutation.
local arr = array({})
arr[#arr + 1] = 1
arr[#arr + 1] = "x"
eq(encode(arr), '[1,"x"]', "marked array tracks mutations")
local obj = object({})
obj.b = 2
obj.a = 1
eq(encode(obj), '{"a":1,"b":2}', "marked object tracks mutations")

-- Marked container validation.
ok(not pcall(encode, array({ [1] = "x", [3] = "y" })),
	"marked array with a hole is rejected")
ok(not pcall(encode, array({ [1] = "x", foo = "bar" })),
	"marked array with a non-numeric key is rejected")
ok(not pcall(encode, object({ [1] = "x" })),
	"marked object with a non-string key is rejected")

-- Untagged empty tables are rejected with an actionable message.
local empty_ok, empty_err = pcall(encode, {})
ok(not empty_ok, "untagged empty table is rejected")
ok(type(empty_err) == "string" and empty_err:find("ambiguous empty table", 1, true),
	"rejection names the ambiguity")
ok(empty_err:find("CanonicalJSON.object({})", 1, true) ~= nil
	and empty_err:find("CanonicalJSON.array({})", 1, true) ~= nil,
	"rejection names both constructors")

-- Existing encoding rules still hold.
eq(encode({ b = 1, a = 2 }), '{"a":2,"b":1}', "unmarked object keys sorted")
eq(encode({ 1, 2, 3 }), "[1,2,3]", "unmarked contiguous sequence is an array")
eq(encode({ z = { 1 }, a = { b = 2 } }), '{"a":{"b":2},"z":[1]}',
	"unmarked nested inference")
eq(encode(object({ a = object({}), b = array({}) })), '{"a":{},"b":[]}',
	"nested marked containers")

local negzero = -0.0
eq(encode(negzero), "-0", "negative zero is preserved")
eq(encode(0), "0", "positive zero stays 0")

local third = 1 / 3
eq(encode(third), string.format("%.17g", third), "1/3 uses %.17g")
eq(decode(encode(third)), third, "1/3 round-trips")
eq(encode(1.5), "1.5", "finite non-integer double")

ok(not pcall(encode, 0 / 0), "NaN is rejected")
ok(not pcall(encode, math.huge), "positive infinity is rejected")
ok(not pcall(encode, -math.huge), "negative infinity is rejected")

-- null still decodes to nil.
eq(decode("null"), nil, "null decodes to nil")
eq(decode('{"a":null,"b":1}').a, nil, "object null member decodes to nil")

-- decode_file round-trip of nested empty containers.
eq(encode(decode('{"x":{"y":[]},"z":{}}')), '{"x":{"y":[]},"z":{}}',
	"nested empty containers preserved")

print(string.format("canonical_json_test: %d checks passed", passed))
