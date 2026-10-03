-- ===========================================================================
-- Exportable: validated recursive deep copy for journal-owned payloads.
--
-- Gameplay event and command payloads must be plain, exportable data:
--   strings, finite numbers, booleans, nil, and recursively exportable tables
--   with string or finite-number keys.
--
-- copy(value, what) returns an independent deep copy and raises an error for:
--   * functions, userdata, threads
--   * NaN, positive/negative infinity (values or keys)
--   * cyclic tables
--   * unsupported key types (boolean/table/function/...)
--
-- The copy is what enforces ownership: a caller-side (possibly live entity)
-- table is never retained by reference, so mutating the original after the
-- call cannot affect the journal. Cyclic structures are rejected outright.
-- ===========================================================================

local Exportable = {}

local function is_finite_number(v)
	return v == v and v ~= math.huge and v ~= -math.huge
end

local function copy_value(value, what, path, seen)
	local t = type(value)
	if t == "nil" or t == "string" or t == "boolean" then
		return value
	end
	if t == "number" then
		if not is_finite_number(value) then
			error(what .. ": non-finite number at " .. path, 3)
		end
		return value
	end
	if t ~= "table" then
		error(what .. ": unsupported value type '" .. t .. "' at " .. path, 3)
	end
	if seen[value] then
		error(what .. ": cyclic table at " .. path, 3)
	end
	seen[value] = true
	local out = {}
	for k, v in pairs(value) do
		local kt = type(k)
		if kt ~= "string" and kt ~= "number" then
			seen[value] = nil
			error(what .. ": unsupported key type '" .. kt .. "' at " .. path, 3)
		end
		if kt == "number" and not is_finite_number(k) then
			seen[value] = nil
			error(what .. ": non-finite numeric key at " .. path, 3)
		end
		out[k] = copy_value(v, what, path .. "." .. tostring(k), seen)
	end
	seen[value] = nil
	return out
end

-- Deep-copy `value`, validating exportability. `what` describes the owner for
-- error messages (e.g. "GameplayEvents.emit_raw('ball_contacted_peg')").
function Exportable.copy(value, what)
	return copy_value(value, what or "exportable", "payload", {})
end

return Exportable
