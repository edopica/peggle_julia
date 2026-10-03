local Config = require("src.config")
local LevelManager = require("src.systems.level_manager")
local MotionSchema = require("src.systems.motion_schema")

local Validator = {}

local function bounding_radius(peg)
	local br = peg.radius
	if peg.shape == "rectangle" then
		-- Approximate bounding radius for rectangle
		br = math.sqrt((peg.width / 2)^2 + (peg.height / 2)^2)
	elseif peg.shape == "annular" then
		br = peg.r_out
	end
	return br or Config.peg_radius
end

local function annular_bounds(peg)
	local min_x, min_y = math.huge, math.huge
	local max_x, max_y = -math.huge, -math.huge
	local function include(angle)
		for _, radius in ipairs({ peg.r_in, peg.r_out }) do
			local x = peg.x + radius * math.cos(angle)
			local y = peg.y + radius * math.sin(angle)
			min_x, max_x = math.min(min_x, x), math.max(max_x, x)
			min_y, max_y = math.min(min_y, y), math.max(max_y, y)
		end
	end
	-- Current angles already include the rotation applied by Peg.set_transform.
	local start, finish = peg.theta_start, peg.theta_end_abs
	include(start)
	include(finish)
	for cardinal = 0, 3 do
		local angle = cardinal * math.pi / 2
		if finish - start >= math.pi * 2
			or (angle - start) % (math.pi * 2) <= finish - start then
			include(angle)
		end
	end
	return min_x, min_y, max_x, max_y
end

local function is_out_of_bounds(peg, width)
	-- Bound the analytic sector, not its inscribed polygon or full circle.
	-- Large-radius biarcs can have distant centers but small in-bounds sectors.
	if peg.shape == "annular" then
		local min_x, min_y, max_x = annular_bounds(peg)
		return min_x < 0 or max_x > width or min_y < 0
	end
	local br = bounding_radius(peg)
	-- Intersecting left wall / right wall / ceiling. The floor is intentionally
	-- not checked: pegs may sit below it.
	return (peg.x - br < 0) or (peg.x + br > width) or (peg.y - br < 0)
end

-- Narrow exemption predicate for the boundary passes. A peg qualifies only
-- when its assigned circuit is a schema-approved closed path: absolute
-- primitive, compiled Path, closed, and every join (including the seam) passes
-- the shared geometry contract. Results are memoized per circuit id so the
-- join check runs once per circuit, not once per peg. Malformed path
-- assignments therefore cannot bypass the boundary pass.
local function make_path_exemption_predicate(circuit_defs)
	local cache = {}
	return function(peg)
		if not circuit_defs or not peg.motion then return false end
		local cid = peg.motion.circuit
		if cid == nil then return false end
		local approved = cache[cid]
		if approved == nil then
			local def = circuit_defs[cid]
			approved = MotionSchema.is_closed_path_circuit(def)
				and (def.path:validate_joins())
			cache[cid] = approved
		end
		return approved
	end
end

function Validator.validate_pegs(pegs, circuit_defs)
	local width = LevelManager.virtual_width
	local valid_pegs = {}
	local is_path_exempt = make_path_exemption_predicate(circuit_defs)

	for _, peg in ipairs(pegs) do
		if is_out_of_bounds(peg, width) then
			if is_path_exempt(peg) then
				-- Intentional hidden-return base: keep it. Return-path safety is
				-- a level geometry/physics-test responsibility, not a filter.
				table.insert(valid_pegs, peg)
			else
				print("WARNING: Discarding peg at (" .. peg.x .. ", " .. peg.y .. ") as it intersects with a wall boundary!")
			end
		else
			table.insert(valid_pegs, peg)
		end
	end

	return valid_pegs
end

-- Boundary-check pegs AFTER motion initialization. Warning-only: discarding
-- pegs here would change peg order and color assignment relative to the
-- base-position pass (validate_pegs).
function Validator.check_initialized_positions(pegs, circuit_defs)
	local width = LevelManager.virtual_width
	local is_path_exempt = make_path_exemption_predicate(circuit_defs)
	local path_pegs_out = 0

	for _, peg in ipairs(pegs) do
		if is_out_of_bounds(peg, width) then
			if is_path_exempt(peg) then
				-- Expected hidden-return position: report the policy once at
				-- the end instead of one warning per peg.
				path_pegs_out = path_pegs_out + 1
			else
				print("WARNING: Peg at initialized position (" .. peg.x .. ", " .. peg.y .. ") intersects a wall boundary; its circuit may sweep out of bounds")
			end
		end
	end

	if path_pegs_out > 0 then
		print(string.format(
			"INFO: %d peg(s) on closed path circuit(s) are outside the playfield at their initialized phase (intentional hidden-return policy; level geometry and physics tests own return-path safety)",
			path_pegs_out))
	end
end

return Validator
