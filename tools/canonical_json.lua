-- Canonical JSON codec for interchange artifacts.
--
-- Encoding rules (stable across runs and machines):
--   * object keys are emitted in ascending lexicographic string order;
--   * arrays keep their 1..n order;
--   * integers with |v| < 2^53 are emitted as decimal integers;
--   * all other finite doubles use %.17g (round-trippable);
--   * negative zero is preserved as -0;
--   * NaN and infinities are rejected (they are not valid JSON and never
--     belong in an authoritative artifact).
--
-- Container kinds are explicit: `CanonicalJSON.array(t)` and
-- `CanonicalJSON.object(t)` mark a table with a metatable so that an empty
-- table encodes as `[]` or `{}` unambiguously. An UNMARKED empty table is a
-- hard error; unmarked non-empty tables keep the historical inference
-- (contiguous integer sequence -> array, otherwise object).
--
-- Decoding is a strict JSON parser used by the round-trip checks. Decoded
-- arrays and objects carry the same markers, so decode -> encode preserves
-- `[]` vs `{}` exactly. `null` decodes to nil; artifacts authored by this
-- codec never contain null.

local CanonicalJSON = {}

local MAX_SAFE_INTEGER = 9007199254740992 -- 2^53

local ARRAY_MARKER = {}
local OBJECT_MARKER = {}

local function fail(message)
	error("CanonicalJSON: " .. message, 3)
end

--- Mark a table as a JSON array and return it. The marker survives later
--- mutations; the table must hold a contiguous 1..n sequence when encoded.
function CanonicalJSON.array(t)
	assert(type(t) == "table", "CanonicalJSON.array expects a table")
	return setmetatable(t, ARRAY_MARKER)
end

--- Mark a table as a JSON object and return it. Keys must be strings when
--- encoded; keys are emitted in ascending lexicographic order.
function CanonicalJSON.object(t)
	assert(type(t) == "table", "CanonicalJSON.object expects a table")
	return setmetatable(t, OBJECT_MARKER)
end

--- Return "array", "object", or nil for an unmarked table.
function CanonicalJSON.kind(t)
	if type(t) ~= "table" then return nil end
	local mt = getmetatable(t)
	if mt == ARRAY_MARKER then return "array" end
	if mt == OBJECT_MARKER then return "object" end
	return nil
end

local function encode_string(s, out)
	out[#out + 1] = '"'
	for i = 1, #s do
		local b = s:byte(i)
		local c = s:sub(i, i)
		if c == '"' then out[#out + 1] = '\\"'
		elseif c == "\\" then out[#out + 1] = "\\\\"
		elseif c == "\b" then out[#out + 1] = "\\b"
		elseif c == "\f" then out[#out + 1] = "\\f"
		elseif c == "\n" then out[#out + 1] = "\\n"
		elseif c == "\r" then out[#out + 1] = "\\r"
		elseif c == "\t" then out[#out + 1] = "\\t"
		elseif b < 0x20 then
			out[#out + 1] = string.format("\\u%04x", b)
		else
			out[#out + 1] = c
		end
	end
	out[#out + 1] = '"'
end

local function encode_number(v, out)
	if v ~= v then fail("cannot encode NaN") end
	if v == math.huge or v == -math.huge then fail("cannot encode infinity") end
	if v == 0 and 1 / v < 0 then
		out[#out + 1] = "-0"
		return
	end
	if v == math.floor(v) and math.abs(v) < MAX_SAFE_INTEGER then
		out[#out + 1] = string.format("%d", v)
		return
	end
	out[#out + 1] = string.format("%.17g", v)
end

local function array_length(v)
	local count = 0
	for k in pairs(v) do
		if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
			return nil
		end
		count = count + 1
	end
	for i = 1, count do
		if v[i] == nil then return nil end
	end
	return count
end

local encode_value

local function encode_array(v, out, path)
	local count = 0
	for k in pairs(v) do
		if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
			fail("array at " .. path .. " has a forbidden key of type "
				.. type(k) .. "; arrays require a contiguous 1..n sequence")
		end
		count = count + 1
	end
	for i = 1, count do
		if v[i] == nil then
			fail("array at " .. path .. " has a hole at index " .. i
				.. "; arrays require a contiguous 1..n sequence")
		end
	end
	out[#out + 1] = "["
	for i = 1, count do
		if i > 1 then out[#out + 1] = "," end
		encode_value(v[i], out, path .. "[" .. i .. "]")
	end
	out[#out + 1] = "]"
end

local function encode_object(v, out, path)
	local keys = {}
	for k in pairs(v) do
		if type(k) ~= "string" then
			fail("object key at " .. path .. " is a " .. type(k)
				.. "; only string keys are supported")
		end
		keys[#keys + 1] = k
	end
	table.sort(keys)
	out[#out + 1] = "{"
	for i, k in ipairs(keys) do
		if i > 1 then out[#out + 1] = "," end
		encode_string(k, out)
		out[#out + 1] = ":"
		encode_value(v[k], out, path .. "." .. k)
	end
	out[#out + 1] = "}"
end

encode_value = function(v, out, path)
	local t = type(v)
	if v == nil then
		out[#out + 1] = "null"
	elseif t == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif t == "number" then
		encode_number(v, out)
	elseif t == "string" then
		encode_string(v, out)
	elseif t == "table" then
		local mt = getmetatable(v)
		if mt == ARRAY_MARKER then
			encode_array(v, out, path)
		elseif mt == OBJECT_MARKER then
			encode_object(v, out, path)
		else
			local n = array_length(v)
			if n ~= nil then
				if n == 0 then
					fail("ambiguous empty table at " .. path
						.. "; use CanonicalJSON.object({}) or CanonicalJSON.array({})")
				end
				out[#out + 1] = "["
				for i = 1, n do
					if i > 1 then out[#out + 1] = "," end
					encode_value(v[i], out, path .. "[" .. i .. "]")
				end
				out[#out + 1] = "]"
			else
				encode_object(v, out, path)
			end
		end
	else
		fail("cannot encode value of type " .. t .. " at " .. path)
	end
end

--- Encode a Lua value as canonical JSON text (no trailing newline).
function CanonicalJSON.encode(value)
	local out = {}
	encode_value(value, out, "$")
	return table.concat(out)
end

-- ===========================================================================
-- Decoder (strict JSON; used by round-trip checks)
-- ===========================================================================

local function decode_error(text, pos, message)
	local line = 1
	local column = 1
	for i = 1, pos - 1 do
		if text:sub(i, i) == "\n" then
			line, column = line + 1, 1
		else
			column = column + 1
		end
	end
	error(string.format("CanonicalJSON: %s at line %d column %d", message, line, column), 3)
end

local function skip_whitespace(text, pos)
	local _, stop = text:find("^[ \t\r\n]*", pos)
	return stop + 1
end

local function utf8_encode(codepoint)
	if codepoint < 0x80 then
		return string.char(codepoint)
	elseif codepoint < 0x800 then
		return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
	elseif codepoint < 0x10000 then
		return string.char(0xE0 + math.floor(codepoint / 0x1000),
			0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
	end
	return string.char(0xF0 + math.floor(codepoint / 0x40000),
		0x80 + math.floor(codepoint / 0x1000) % 0x40,
		0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
end

local function decode_string(text, pos)
	pos = pos + 1 -- opening quote
	local out = {}
	local start = pos
	while true do
		if pos > #text then decode_error(text, pos, "unterminated string") end
		local c = text:sub(pos, pos)
		if c == '"' then
			out[#out + 1] = text:sub(start, pos - 1)
			return table.concat(out), pos + 1
		elseif c == "\\" then
			out[#out + 1] = text:sub(start, pos - 1)
			local esc = text:sub(pos + 1, pos + 1)
			local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
				f = "\f", n = "\n", r = "\r", t = "\t" }
			if simple[esc] then
				out[#out + 1] = simple[esc]
				pos = pos + 2
			elseif esc == "u" then
				local hex = text:sub(pos + 2, pos + 5)
				if not hex:match("^%x%x%x%x$") then
					decode_error(text, pos, "invalid unicode escape")
				end
				out[#out + 1] = utf8_encode(tonumber(hex, 16))
				pos = pos + 6
			else
				decode_error(text, pos, "invalid escape")
			end
			start = pos
		else
			pos = pos + 1
		end
	end
end

local function decode_number(text, pos)
	local literal = text:match("^-?%d+%.?%d*[eE][+-]?%d+", pos)
		or text:match("^-?%d+%.%d+", pos)
		or text:match("^-?%d+", pos)
	if not literal then decode_error(text, pos, "invalid number") end
	return tonumber(literal), pos + #literal
end

local decode_value

local function decode_array(text, pos)
	pos = pos + 1 -- [
	local out = CanonicalJSON.array({})
	pos = skip_whitespace(text, pos)
	if text:sub(pos, pos) == "]" then return out, pos + 1 end
	while true do
		local value
		value, pos = decode_value(text, pos)
		out[#out + 1] = value
		pos = skip_whitespace(text, pos)
		local c = text:sub(pos, pos)
		if c == "," then
			pos = skip_whitespace(text, pos + 1)
		elseif c == "]" then
			return out, pos + 1
		else
			decode_error(text, pos, "expected ',' or ']'")
		end
	end
end

local function decode_object(text, pos)
	pos = pos + 1 -- {
	local out = CanonicalJSON.object({})
	pos = skip_whitespace(text, pos)
	if text:sub(pos, pos) == "}" then return out, pos + 1 end
	while true do
		if text:sub(pos, pos) ~= '"' then decode_error(text, pos, "expected object key") end
		local key
		key, pos = decode_string(text, pos)
		pos = skip_whitespace(text, pos)
		if text:sub(pos, pos) ~= ":" then decode_error(text, pos, "expected ':'") end
		pos = skip_whitespace(text, pos + 1)
		local value
		value, pos = decode_value(text, pos)
		out[key] = value
		pos = skip_whitespace(text, pos)
		local c = text:sub(pos, pos)
		if c == "," then
			pos = skip_whitespace(text, pos + 1)
		elseif c == "}" then
			return out, pos + 1
		else
			decode_error(text, pos, "expected ',' or '}'")
		end
	end
end

decode_value = function(text, pos)
	local c = text:sub(pos, pos)
	if c == "{" then return decode_object(text, pos) end
	if c == "[" then return decode_array(text, pos) end
	if c == '"' then return decode_string(text, pos) end
	if text:sub(pos, pos + 3) == "true" then return true, pos + 4 end
	if text:sub(pos, pos + 4) == "false" then return false, pos + 5 end
	if text:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
	return decode_number(text, pos)
end

--- Decode a JSON document. Raises on malformed input or trailing garbage.
function CanonicalJSON.decode(text)
	if type(text) ~= "string" then fail("decode expects a string") end
	local pos = skip_whitespace(text, 1)
	local value, after = decode_value(text, pos)
	after = skip_whitespace(text, after)
	if after <= #text then decode_error(text, after, "trailing characters") end
	return value
end

--- Read and decode a JSON file.
function CanonicalJSON.decode_file(path)
	local f, err = io.open(path, "r")
	if not f then error("CanonicalJSON: cannot open " .. path .. ": " .. tostring(err), 2) end
	local text = f:read("*a")
	f:close()
	return CanonicalJSON.decode(text)
end

return CanonicalJSON
