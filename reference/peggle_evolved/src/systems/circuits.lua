-- ===========================================================================
-- Circuits: peg movement along parametric paths.
--
-- Circuit definitions live at level scope (level_circuits) and are immutable
-- during simulation. Each moving peg owns its assignment and runtime motion
-- state in `peg.motion`:
--
--   peg.motion = {
--       circuit = "orbit",  -- reference into level_circuits (authoring)
--       phase   = 1.5,      -- declared initial path position (authoring)
--       time    = 1.5,      -- runtime path time (advances by speed * dt)
--       state   = "moving", -- "moving" | "paused"
--       timer   = 0,        -- move/pause cycle timer (seconds)
--   }
--
-- `phase` and `time` are in the primitive's own argument units. For kind
-- "path" they are distances in pixels along the compiled path (speed is in
-- px/s and `time % path:length()` selects the sampled point).
--
-- Contract (used by CCD — see also ImpactGeometry.peg_transform_at_toi):
--   * Circuits.initialize() applies the declared phase transform during level
--     setup, BEFORE the first simulation step, with zero velocity.
--   * Circuits.update() applies the END transform of the step and computes
--     per-step velocities as the secant (end - start) / dt. A fully paused
--     interval yields exactly zero velocity because path time is frozen.
--   * Velocities reflect actual movement for transition steps (move→pause
--     keeps the final sweep; pause→move carries timer overshoot into time).
--   * Absolute primitives (CircuitPrimitives.is_absolute) return world-space
--     positions; the peg base is ignored. Relative primitives translate the
--     base. Circuits.world_position() is the shared resolution point.
-- ===========================================================================

local CircuitPrimitives = require("src.systems.circuit_primitives")
local Peg = require("src.entities.peg")

local Circuits = {}

-- Resolve the circuit definition for a peg, or nil when it does not move.
local function circuit_for(peg, circuit_defs)
	if not circuit_defs then return nil end
	local motion = peg.motion
	if not motion then return nil end
	return circuit_defs[motion.circuit]
end

-- True when the circuit's eval result is a world-space position rather than a
-- base-relative offset. Single classification source: CircuitPrimitives.
function Circuits.is_absolute(circuit)
	return CircuitPrimitives.is_absolute(circuit)
end

-- Evaluate the path offset (dx, dy, da) of a circuit definition at a time.
function Circuits.eval_transform(circuit, time)
	local dx, dy, da
	if circuit.path_fn then
		dx, dy, da = circuit.path_fn(time)
	else
		dx, dy, da = CircuitPrimitives.eval(circuit, time)
	end
	return dx or 0, dy or 0, da or 0
end

-- Final world position for a peg at `time`. Absolute primitives ignore the
-- declared base entirely; relative primitives translate it.
function Circuits.world_position(circuit, time, base_x, base_y)
	local dx, dy = Circuits.eval_transform(circuit, time)
	if CircuitPrimitives.is_absolute(circuit) then
		return dx, dy
	end
	return base_x + dx, base_y + dy
end

-- Apply the circuit path position at the given time to the peg (without
-- touching velocities).
local function apply_transform(peg, circuit, time)
	local dx, dy, da = Circuits.eval_transform(circuit, time)
	local new_x, new_y
	if CircuitPrimitives.is_absolute(circuit) then
		new_x, new_y = dx, dy
	else
		new_x, new_y = peg.base_x + dx, peg.base_y + dy
	end
	local new_angle = (peg.base_angle or 0) + da
	Peg.set_transform(peg, new_x, new_y, new_angle)
end

-- Initialize every moving peg during level setup (before gameplay starts):
--   1. Copy the declared phase to runtime motion time.
--   2. Set the initial state to "moving".
--   3. Set the initial timer to zero.
--   4. Evaluate the circuit at the declared phase.
--   5. Apply the resulting transform without advancing time.
--   6. Set vx, vy, and va to zero.
--   7. Initialize the previous render transform from this position.
function Circuits.initialize(pegs, circuit_defs)
	if not circuit_defs then return end

	for _, peg in ipairs(pegs) do
		local circuit = circuit_for(peg, circuit_defs)
		if circuit then
			local motion = peg.motion
			motion.time = motion.phase or 0
			motion.state = "moving"
			motion.timer = 0

			apply_transform(peg, circuit, motion.time)

			peg.vx = 0
			peg.vy = 0
			peg.va = 0

			peg.prev_x = peg.x
			peg.prev_y = peg.y
			if peg.shape == "rectangle" or peg.shape == "annular" then
				peg.prev_angle = peg.angle or 0
			end
		end
	end
end

-- Advance one peg's motion state through one complete dt-sized interval,
-- consuming it in segments across every move/pause boundary it crosses.
-- The timer counts elapsed time within the current state only; path time
-- advances (at speed) only while moving. Portions of dt that fall after a
-- boundary stay on the timer of the state they were spent in.
local function advance_motion(motion, circuit, dt)
	local speed = circuit.speed or 1
	local remaining = dt

	while remaining > 0 do
		if motion.state == "moving" then
			local duration_time = circuit.duration_time
			if duration_time and duration_time > 0 then
				local budget = duration_time - motion.timer
				if remaining < budget then
					-- The whole step stays within the move phase.
					motion.time = motion.time + speed * remaining
					motion.timer = motion.timer + remaining
					remaining = 0
				else
					-- Reach the pause boundary; the leftover of the step is
					-- paused time and must not advance path time.
					motion.time = motion.time + speed * budget
					motion.timer = 0
					motion.state = "paused"
					remaining = remaining - budget
				end
			else
				motion.time = motion.time + speed * remaining
				remaining = 0
			end
		else -- "paused"
			local pause_time = circuit.pause_time
			if pause_time and pause_time > 0 then
				local budget = pause_time - motion.timer
				if remaining < budget then
					motion.timer = motion.timer + remaining
					remaining = 0
				else
					-- Reach the resume boundary; the leftover of the step was
					-- spent moving, so it advances both timer and path time.
					motion.timer = 0
					motion.state = "moving"
					remaining = remaining - budget
				end
			else
				motion.timer = motion.timer + remaining
				remaining = 0
			end
		end
	end
end

-- Advance every moving peg through one fixed step:
--   1. Save the start transform.
--   2. Advance the motion state through the complete time interval.
--   3. Preserve timer overshoot across move and pause boundaries.
--   4. Evaluate the end transform.
--   5. Apply the transform through Peg.set_transform().
--   6. Compute velocity from the start and end transforms.
--
-- A fully paused step keeps path time frozen, so its secant velocity is
-- exactly zero.
function Circuits.update(pegs, circuit_defs, dt)
	if not circuit_defs then return end

	for _, peg in ipairs(pegs) do
		local circuit = circuit_for(peg, circuit_defs)
		if circuit then
			local start_x = peg.x
			local start_y = peg.y
			local start_angle = peg.angle or peg.base_angle or 0

			advance_motion(peg.motion, circuit, dt)

			apply_transform(peg, circuit, peg.motion.time)

			peg.vx = (peg.x - start_x) / dt
			peg.vy = (peg.y - start_y) / dt
			peg.va = (peg.angle - start_angle) / dt
		end
	end
end

return Circuits
