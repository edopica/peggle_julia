local Config = require("src.config")
local Physics = require("src.systems.physics")
local Powers = require("src.systems.powers")
local PegColors = require("src.systems.peg_colors")
local Circuits = require("src.systems.circuits")
local MotionSchema = require("src.systems.motion_schema")
local Lines = require("src.systems.lines")
local Ball = require("src.entities.ball")
local Validator = require("src.systems.level_validator")
local Peg = require("src.entities.peg")
local Bucket = require("src.entities.bucket")
local FeverBuckets = require("src.entities.fever_buckets")
local Screen = require("src.systems.screen")
local LevelManager = require("src.systems.level_manager")
local Perf = require("src.systems.perf")
local TraceExporter = require("src.systems.trace_exporter")
local Replay = require("src.systems.replay")
local ReplayLibrary = require("src.systems.replay_library")
local ImpactDebug = require("src.systems.impact_debug")
local ContactEvents = require("src.systems.contact_events")

local Exportable = require("src.systems.exportable")

local GameplayEvents = require("src.systems.gameplay_events")
local GameplayCommands = require("src.systems.gameplay_commands")
local StyleShots = require("src.systems.style_shots")
local BallState = require("src.systems.ball_state")
local SlideInversion = require("src.systems.slide_inversion")
local SimulationSnapshot = require("src.systems.simulation_snapshot")
local GameplayTraceExporter = require("src.systems.gameplay_trace_exporter")

local Engine = {}
local Engine_mt = { __index = Engine }

-- Maximum normalized time-of-impact spread for two line contacts to count as
-- one simultaneous shared-boundary crossing. Contacts in the same CCD
-- iteration but at different TOIs are sequential physical crossings (e.g. a
-- ball grazing two pegs along a slide) and must both score.
local SEAM_TOI_EPSILON = 0.05

-- Rolling capture of the most recent shot (used by `make trace`). Overridable
-- per engine instance so tests can redirect it away from the repo.
local DEFAULT_LAST_SHOT_PATH = "src/replays/last_shot.lua"

function Engine.new(callbacks)
	local self = setmetatable({}, Engine_mt)
	self.callbacks = callbacks or {}

	self.level_name = ""
	self.accumulator = 0
	self.active_balls = {}
	self.pegs = {}
	self.circle_pegs = {}
	self.rect_pegs = {}
	self.annular_pegs = {}
	self.peg_by_id = {}
	self.level_circuits = {}
	self.bucket = nil
	self.feverBuckets = nil
	self.bonusScore = 0
	self.styleScore = 0
	self.totalRedPegs = 0
	self.turnPegsHit = {}
	self.currentMultiplier = 1
	self.isFever = false
	self.redPegsHitAmount = 0
	self.hitCounter = 0
	self.clearQueue = nil
	self.clearTimer = 0
	self.clearingIsEndOfTurn = false
	self.scoredThisStep = false
	self.current_aim_angle = math.pi / 2
	self.key_hold_time_left = 0
	self.key_hold_time_right = 0
	self.is_halted = false

	-- Presentation instrumentation counters (monotonically increasing).
	self.sim_step_id = 0           -- incremented once per fixed simulation step
	self.render_frame_id = 0       -- incremented once per Engine:draw
	self.steps_since_last_draw = 0 -- fixed steps since the last Engine:draw

	-- Stable identities (scoped to the lifetime of one Engine instance).
	-- Engine.new() starts the identity namespace. IDs do not reset during
	-- setupLevel(), resetTurn(), shot completion, clearing, or ball removal.
	self.next_ball_id = 1       -- next candidate for automatic allocation
	self.used_ball_ids = {}     -- [id] = true permanently; never removed
	self.live_ball_ids = {}     -- ball_id -> ball (currently registered/live balls)
	self.live_id_by_ball = {}   -- ball -> ball_id (reverse mapping for idempotent re-registration and mutation detection)
	self.shot_id = 0
	self.shot_initial_step = 0
	self.shot_final_step = 0
	self.shot_end_reason = nil
	self.last_removal_reason = nil

	-- Gameplay event pipeline (instance-scoped, deterministic).
	self.events = GameplayEvents.new()
	self.commands = GameplayCommands.new()
	self.styleShots = StyleShots.new()
	self.ballState = BallState.new()
	self.slideInversion = SlideInversion.new()

	-- Buffered peg_scored events (filled by reducer, appended after seal).
	self.buffered_peg_scored = nil
	-- Power-spawned ball specs (created during reduction, added after removal).
	self.pending_spawn_specs = nil

	-- Optional shot-level timeline retention (disabled by default).
	self.retain_shot_timeline = false
	self.shot_timelines = {}      -- shot_id -> timeline record
	self.current_shot_timeline = nil

	-- Canonical gameplay trace exporter (nil unless enabled via CLI).
	self.trace_exporter = nil

	-- Serialized launch state of the most recent shot (schema-2 capture Lua
	-- source). Kept in memory so the player can explicitly save it later via
	-- Engine:saveLastShotReplay without losing the launch state.
	self.last_shot_replay_lua = nil
	self.last_shot_replay_path = DEFAULT_LAST_SHOT_PATH

	-- Headless mode: disables presentation side effects (contact-present,
	-- impact markers) so the authoritative simulation runs identically with
	-- or without rendering.
	self.headless = false

	return self
end

-- ===========================================================================
-- Stable identities
-- ===========================================================================

-- Largest integer exactly representable in a Lua double (2^53 - 1).
-- All ball IDs must be positive finite integers at or below this value.
-- Defined once here rather than scattered as a magic number.
local MAX_BALL_ID = 9007199254740991 -- 2^53 - 1

-- Validate that a candidate ball ID is a positive finite integer.
-- Returns true on success, or false, error_message on failure.
function Engine.validateBallId(id)
	if type(id) ~= "number" then
		return false, "ball id must be a number, got " .. type(id)
	end
	if id ~= id then
		return false, "ball id must not be NaN"
	end
	if id == math.huge then
		return false, "ball id must not be positive infinity"
	end
	if id == -math.huge then
		return false, "ball id must not be negative infinity"
	end
	if id <= 0 then
		return false, "ball id must be positive, got " .. tostring(id)
	end
	if id ~= math.floor(id) then
		return false, "ball id must be an integer, got " .. tostring(id)
	end
	if id > MAX_BALL_ID then
		return false, "ball id exceeds maximum representable integer (" .. MAX_BALL_ID .. ")"
	end
	return true
end

-- Assign a stable integer ID to a ball and register it as live. Called by
-- the Engine for every entry path (resetTurn, bench, replay, power spawns).
--
-- Contract (identity namespace scoped to the lifetime of one Engine instance):
--   * Ball IDs are positive finite integers <= 2^53-1, never derived from
--     table identity, wall-clock time, RNG, or hash iteration order.
--   * An ID is consumed permanently for the lifetime of this Engine.
--     Removing a ball does not make its ID reusable.
--   * Two different balls must never receive the same ID, even after removal.
--   * A ball without an ID receives the next available monotonically
--     increasing automatic ID.
--   * An explicitly supplied valid ID is preserved.
--   * Registering an explicit ID advances the automatic allocator to at
--     least id + 1. Explicit IDs may arrive out of numeric order; the next
--     automatic ID is always strictly greater than every consumed ID.
--   * Registering the SAME ball (same table) more than once is idempotent
--     (returns the same ball without consuming another ID).
--   * Changing a ball's ID while it is registered is an error.
--   * On any rejected registration, no allocator state, used-ID set, or live
--     mapping is mutated.
--   * Automatic allocation is valid only while a monotonically increasing
--     candidate at or below MAX_BALL_ID (2^53-1) exists. When next_ball_id
--     reaches MAX_BALL_ID + 1 it forms a stable sentinel/frontier signalling
--     an exhausted automatic allocator; further automatic registrations fail
--     with a clear error before any state change. The sentinel is never
--     assigned to a ball.
function Engine:registerBall(b)
	local id = b.id

	if id == nil then
		-- Compute a candidate without mutating next_ball_id yet, so
		-- allocator-exhaustion can be detected atomically before any
		-- state change.
		local candidate = self.next_ball_id
		while self.used_ball_ids[candidate] do
			candidate = candidate + 1
		end
		if candidate > MAX_BALL_ID then
			error("Engine:registerBall: allocator exhausted, no valid automatic ball ID available", 2)
		end
		id = candidate
	else
		local ok, err = Engine.validateBallId(id)
		if not ok then
			error("Engine:registerBall: " .. err, 2)
		end
	end

	-- Idempotent re-registration of the same ball table.
	local existing_id = self.live_id_by_ball[b]
	if existing_id ~= nil then
		if existing_id == id then
			return b
		end
		error("Engine:registerBall: ball id changed from "
			.. tostring(existing_id) .. " to " .. tostring(id)
			.. " while registered", 2)
	end

	-- Reject reuse of a permanently consumed ID.
	if self.used_ball_ids[id] then
		error("Engine:registerBall: ball id " .. tostring(id)
			.. " already consumed and cannot be reused", 2)
	end

	-- Reject a live-ball duplicate.
	if self.live_ball_ids[id] ~= nil then
		error("Engine:registerBall: duplicate live ball id "
			.. tostring(id), 2)
	end

	-- All validations passed: commit.
	if b.id == nil then
		b.id = id
	end
	self.used_ball_ids[id] = true
	self.live_ball_ids[id] = b
	self.live_id_by_ball[b] = id
	if id >= self.next_ball_id then
		self.next_ball_id = id + 1
	end
	return b
end

-- Mark a ball as no longer live (removed from play). Its ID stays
-- permanently consumed (used_ball_ids is not touched). Only live
-- mappings are removed.
--
-- Uses the registered mapping rather than trusting a possibly changed b.id.
-- Detects ID mutation and inconsistent live mappings.
function Engine:unregisterBall(b)
	if not b then return end
	local id = self.live_id_by_ball[b]
	if id == nil then return end

	if b.id ~= id then
		error("Engine:unregisterBall: ball id changed from "
			.. tostring(id) .. " to " .. tostring(b.id)
			.. " while registered", 2)
	end

	if self.live_ball_ids[id] ~= b then
		error("Engine:unregisterBall: live mapping inconsistent for id "
			.. tostring(id), 2)
	end

	self.live_ball_ids[id] = nil
	self.live_id_by_ball[b] = nil
end

-- Engine-controlled factory for power-spawned balls. Powers returns spawn
-- specs; the Engine creates, registers, and stages the balls so they begin
-- physics on the following fixed step (never retroactively).
function Engine:stagePowerSpawns(specs)
	if not specs then return end
	for _, spec in ipairs(specs) do
		table.insert(self.pending_spawn_specs, spec)
	end
end

function Engine:getTurnScore()
	local weightedSum = 0
	local count = 0
	for _, peg in ipairs(self.turnPegsHit) do
		weightedSum = weightedSum + Peg.value(peg) * (peg.multiplier_at_hit or 1)
		count = count + 1
	end
	return weightedSum * count + self.bonusScore + self.styleScore
end

-- Peg-score contribution only (weightedSum * pegCount), excluding bonus/style.
function Engine:getTurnPegScore()
	local weightedSum = 0
	local count = 0
	for _, peg in ipairs(self.turnPegsHit) do
		weightedSum = weightedSum + Peg.value(peg) * (peg.multiplier_at_hit or 1)
		count = count + 1
	end
	return weightedSum * count
end

function Engine:updateMultiplier()
	local wasFever = self.isFever
	if self.totalRedPegs == 0 then
		self.currentMultiplier = 1
	else
		local percentage = self.redPegsHitAmount / self.totalRedPegs
		if percentage >= 1.0 then self.currentMultiplier = 100
		elseif percentage >= 0.88 then self.currentMultiplier = 10
		elseif percentage >= 0.75 then self.currentMultiplier = 5
		elseif percentage >= 0.60 then self.currentMultiplier = 3
		elseif percentage >= 0.40 then self.currentMultiplier = 2
		else self.currentMultiplier = 1 end
	end
	self.isFever = self.currentMultiplier == 100
	if self.isFever and not wasFever then
		FeverBuckets.activate(self.feverBuckets)
	end
end

function Engine:setupLevel(level_name)
	self.level_name = level_name
	ContactEvents.clear()
	local level_data = LevelManager.load(level_name)

	local raw_pegs = level_data.pegs or {}
	self.pegs = {}
	for _, p in ipairs(raw_pegs) do
		if p.radius and p.base_x then
			table.insert(self.pegs, p)
		else
			local new_p = Peg.new(p.x, p.y, p.type, p.radius)
			for k, v in pairs(p) do
				new_p[k] = v
			end
			table.insert(self.pegs, new_p)
		end
	end

	-- Circuit definitions live at level scope; each moving peg owns its
	-- assignment and runtime state in peg.motion. level_data.pegs is the
	-- only peg collection (no circuit.pegs merge).
	self.level_circuits = level_data.level_circuits or {}
	MotionSchema.validate(self.pegs, self.level_circuits)

	-- Validate authored line metadata before boundary filtering can discard
	-- members: malformed or inconsistent metadata must fail at load time, not
	-- later during Replay.capture (which math.floor's line.index/count).
	Lines.validate(self.pegs)

	-- Discard pegs whose base position intersects a wall boundary (authoring
	-- safety, unchanged from the pre-motion schema). Pegs assigned to a
	-- schema-approved closed path circuit are exempt: their bases follow a
	-- hidden return leg and are intentionally off-screen.
	self.pegs = Validator.validate_pegs(self.pegs, self.level_circuits)

	-- Boundary filtering can remove one member of a line group while leaving
	-- the remaining members' index/count metadata stale. Re-validate so that
	-- stale groups become a load-time error instead of a replay-capture crash.
	Lines.validate(self.pegs)

	-- Initialize motion transforms at the declared phase before gameplay
	-- starts (no first-step teleport).
	Circuits.initialize(self.pegs, self.level_circuits)

	-- Boundary-check the initialized positions. This only warns: discarding
	-- here would change peg order and color assignment relative to the
	-- base-position pass.
	Validator.check_initialized_positions(self.pegs, self.level_circuits)

	for i, p in ipairs(self.pegs) do
		p.original_index = i
	end

	self:rebuildPegLists()
	self:rebuildPegIdMap()

	local type_counts = level_data.type_counts or { red = 10, green = 2 }
	type_counts.blue = #self.pegs - ((type_counts.red or 0) + (type_counts.green or 0))
	self.totalRedPegs = type_counts.red
	local level_seed = level_data.level_seed or 345

	PegColors.init(self.pegs, type_counts, level_seed)

	self.hitCounter = 0
	self.bonusScore = 0
	self.styleScore = 0
	self.turnPegsHit = {}
	self.bucket = Bucket.new()
	self.feverBuckets = FeverBuckets.new()
	self.redPegsHitAmount = 0
	self.clearQueue = nil
	-- Clear stale active balls from the previous level (unregister cleans
	-- live mappings but the permanent identity namespace is preserved).
	for _, b in ipairs(self.active_balls) do
		self:unregisterBall(b)
	end
	self.active_balls = {}
	-- Explicitly replace live registries so no stale mappings (from balls
	-- that were registered but not in active_balls) survive a new level.
	self.live_ball_ids = {}
	self.live_id_by_ball = {}
	-- Shot/clearing state is reset; ball ID namespace is NOT.
	self.shot_id = 0
	self.shot_initial_step = 0
	self.shot_final_step = 0
	self.shot_end_reason = nil
	self.last_removal_reason = nil
	self:updateMultiplier()

	-- Reset gameplay event pipeline state.
	self.events:reset()
	self.commands:reset()
	self.styleShots:reset_shot()
	self.ballState:reset_shot()
	self.slideInversion:reset_shot()
	self.shot_timelines = {}
	self.current_shot_timeline = nil

	if self.callbacks.onHUDRefresh then self.callbacks.onHUDRefresh(self) end
end

function Engine:rebuildPegLists()
	self.circle_pegs = {}
	self.rect_pegs = {}
	self.annular_pegs = {}
	for _, p in ipairs(self.pegs) do
		if not p.shape or p.shape == "circle" then
			table.insert(self.circle_pegs, p)
		elseif p.shape == "rectangle" then
			table.insert(self.rect_pegs, p)
		elseif p.shape == "annular" then
			table.insert(self.annular_pegs, p)
		end
	end
end

function Engine:rebuildPegIdMap()
	self.peg_by_id = {}
	for _, p in ipairs(self.pegs) do
		self.peg_by_id[p.original_index] = p
	end
end

-- Preflight: plan registrations for a batch of balls without mutating the
-- Engine or Ball objects. Returns an ordered plan ({{ball, id, was_auto},...})
-- and the next_ball_id frontier, or nil, error_message on failure.
--
-- Rules mirror registerBall: valid IDs, deterministic sequential
-- allocation, no reuse of permanently consumed IDs, no within-batch
-- duplicates, same-Ball idempotence.
function Engine:_planBallRegistrations(balls, caller_name)
	caller_name = caller_name or "Engine"
	local plan = {}
	local shadow_next = self.next_ball_id
	local shadow_used = {}
	local shadow_ball_to_id = {}

	for _, b in ipairs(balls) do
		-- Same-Ball idempotence: if this table was already planned in this
		-- batch, treat subsequent appearances as idempotent no-ops.
		local previous_id = shadow_ball_to_id[b]
		if previous_id ~= nil then
			if b.id ~= nil and b.id ~= previous_id then
				return nil, caller_name .. ": ball id changed from "
					.. tostring(previous_id) .. " to " .. tostring(b.id)
					.. " in replacement batch"
			end
		else
			local id = b.id
			if id == nil then
				local candidate = shadow_next
				while self.used_ball_ids[candidate] or shadow_used[candidate] do
					candidate = candidate + 1
				end
				if candidate > MAX_BALL_ID then
					return nil, caller_name .. ": allocator exhausted,"
						.. " no valid automatic ball ID available"
				end
				id = candidate
			else
				local ok, err = Engine.validateBallId(id)
				if not ok then
					return nil, caller_name .. ": " .. err
				end
			end

			if self.used_ball_ids[id] or shadow_used[id] then
				return nil, caller_name .. ": ball id " .. tostring(id)
					.. " already consumed and cannot be reused"
			end

			shadow_used[id] = true
			shadow_ball_to_id[b] = id
			if id >= shadow_next then
				shadow_next = id + 1
			end

			table.insert(plan, {ball = b, id = id, was_auto = (b.id == nil)})
		end
	end

	return plan, shadow_next
end

function Engine:resetTurn(initial_balls)
	-- The previous turn's balls are wholesale replaced: none of them are live.
	-- (The allocator stays monotonic; consumed IDs are never reused.)
	local replacement_balls = initial_balls
		or { Ball.new(LevelManager.virtual_width / 2, 50) }

	-- Phase A: preflight — validate and plan every registration before any
	-- Engine or Ball mutation.
	local plan, new_next = self:_planBallRegistrations(replacement_balls, "Engine:resetTurn")
	if plan == nil then
		error(new_next, 2) -- new_next holds the error message
	end

	-- Phase B: commit — all validations passed; install new state.
	self.live_ball_ids = {}
	self.live_id_by_ball = {}
	self.active_balls = replacement_balls
	for _, entry in ipairs(plan) do
		local b = entry.ball
		local id = entry.id
		if entry.was_auto then
			b.id = id
		end
		self.used_ball_ids[id] = true
		self.live_ball_ids[id] = b
		self.live_id_by_ball[b] = id
	end
	self.next_ball_id = new_next

	-- Gameplay resets — none of these can fail due to identity issues.
	self.clearQueue = nil
	self.clearTimer = 0
	self.turnPegsHit = {}
	self.scoredThisStep = false
	self.bonusScore = 0
	self.styleScore = 0
	self.styleShots:reset_shot()
	self.ballState:reset_shot()
	self.slideInversion:reset_shot()
	self.shot_end_reason = nil
	self.last_removal_reason = nil
	self.current_shot_timeline = nil
	PegColors.assign_next_purple_peg()
	if self.callbacks.onHUDRefresh then self.callbacks.onHUDRefresh(self) end
end

-- Apply a replay capture to this Engine. The level must already be set up
-- (setupLevel). A replay capture represents a shot ALREADY IN PROGRESS:
-- captured balls are launched and mid-flight.
--
-- Compatibility contract:
--   * New captures include stable ball IDs; those IDs are preserved.
--   * Old captures without ball IDs remain loadable; IDs are allocated
--     deterministically in ball order via registerBall (which also advances
--     the allocator so power-created balls can never reuse replay IDs).
--   * The loaded shot runs under a valid NONZERO shot_id with a deterministic
--     shot_initial_step. No fake ball_launched event is staged (the launch
--     predates the capture).
--   * StyleShots and BallState are reset for the loaded active shot.
function Engine:applyReplayState(replay_data)
	-- Schema gate: Replay.validate is structural and runs before ANY state
	-- mutation (including the Phase A preflight below), so an unsupported
	-- schema_version or a malformed capture fails atomically and leaves the
	-- Engine untouched.
	local ok, verr = Replay.validate(replay_data)
	if not ok then
		error("Engine:applyReplayState: " .. verr, 2)
	end

	-- Phase A: preflight — construct candidate Ball objects locally and
	-- plan registrations before any authoritative Engine mutation.
	local candidate_balls = {}
	for _, rb in ipairs(replay_data.balls or {}) do
		local b = Ball.new(rb.x, rb.y)
		b.vx = rb.vx
		b.vy = rb.vy
		b.launched = true
		if rb.id ~= nil then
			b.id = rb.id
		end
		table.insert(candidate_balls, b)
	end

	local plan, new_next
	if #candidate_balls > 0 then
		plan, new_next = self:_planBallRegistrations(candidate_balls, "Engine:applyReplayState")
		if plan == nil then
			error(new_next, 2)
		end
	end

	-- Phase B: commit — all validations passed; install replay state.
	self.isFever = replay_data.isFever or false
	if self.isFever then
		FeverBuckets.activate(self.feverBuckets)
	end

	-- Pegs: keep only pegs present in the capture, restore captured state.
	local replay_pegs_by_id = {}
	for _, rp in ipairs(replay_data.pegs or {}) do
		replay_pegs_by_id[rp.original_index] = rp
	end

	-- Restore one peg's captured state.
	--   * schema 2 captures: restore the runtime motion state and the captured
	--     transform/velocities directly.
	--   * Legacy captures (flat circuit fields): convert to peg.motion using
	--     the level's circuit assignment, re-derive the transform from the
	--     circuit at circuit_t, and zero velocities (they are recomputed on
	--     the next fixed step with no first-step jump).
	local is_schema_2 = Replay.is_schema_2(replay_data)
	local function restore_peg(p, rp)
		if is_schema_2 then
			if rp.motion then
				local m = p.motion or {}
				m.circuit = rp.motion.circuit or m.circuit
				m.phase = rp.motion.phase or 0
				m.time = rp.motion.time or m.phase or 0
				m.state = rp.motion.state or "moving"
				m.timer = rp.motion.timer or 0
				p.motion = m
			else
				-- The capture is authoritative: no motion record means the
				-- peg does not move in this replay.
				p.motion = nil
			end
			local x = rp.x ~= nil and rp.x or p.base_x
			local y = rp.y ~= nil and rp.y or p.base_y
			local angle = rp.angle ~= nil and rp.angle or 0
			Peg.set_transform(p, x, y, angle)
			p.vx = rp.vx or 0
			p.vy = rp.vy or 0
			p.va = rp.va or 0
		else
			local circuit_id = (p.motion and p.motion.circuit) or rp.circuit_id
			local circuit = circuit_id and self.level_circuits[circuit_id] or nil
			if circuit and rp.circuit_t ~= nil then
				local m = p.motion or {}
				m.circuit = circuit_id
				m.time = rp.circuit_t
				m.state = rp.circuit_state or "moving"
				m.timer = rp.circuit_timer or 0
				p.motion = m
				local wx, wy = Circuits.world_position(circuit, rp.circuit_t,
					p.base_x, p.base_y)
				local _, _, da = Circuits.eval_transform(circuit, rp.circuit_t)
				Peg.set_transform(p, wx, wy, (p.base_angle or 0) + da)
			else
				-- Static peg: place it at its captured base transform.
				Peg.set_transform(p, p.base_x, p.base_y, p.base_angle or 0)
			end
			p.vx = 0
			p.vy = 0
			p.va = 0
		end

		-- No first-step jump: the next step's interpolation and CCD sweep
		-- start from the restored transform.
		p.prev_x = p.x
		p.prev_y = p.y
		if p.shape == "rectangle" or p.shape == "annular" then
			p.prev_angle = p.angle or 0
		end
	end

	local new_pegs = {}
	for _, p in ipairs(self.pegs) do
		local rp = replay_pegs_by_id[p.original_index]
		if rp then
			p.type = rp.type
			p.hit = rp.hit
			if is_schema_2 then
				p.hit_order = rp.hit_order
			end
			-- Captured base transforms are authoritative when present; old
			-- synthetic captures without them keep the level's base position.
			p.base_x = rp.base_x ~= nil and rp.base_x or p.base_x
			p.base_y = rp.base_y ~= nil and rp.base_y or p.base_y
			if is_schema_2 then
				-- Schema 2 records the declared base rotation.
				p.base_angle = rp.base_angle ~= nil and rp.base_angle or 0
			end
			-- Legacy captures predate the declared-base invariant: annular
			-- pegs had no base_angle field, so old captures wrote the current
			-- applied rotation there. Trusting it would double the circuit
			-- rotation (base_angle + evaluated da); the level's declared
			-- base rotation is authoritative instead.
			restore_peg(p, rp)
			table.insert(new_pegs, p)
		end
	end
	self.pegs = new_pegs
	self:rebuildPegLists()
	self:rebuildPegIdMap()

	-- Schema 2 captures record the scoring counter so mid-shot captures keep
	-- a consistent hit_order sequence for the clearing cascade.
	if is_schema_2 and replay_data.hitCounter ~= nil then
		self.hitCounter = replay_data.hitCounter
	end

	-- Schema 2 scoring progress: redPegsHitAmount is authoritative; the
	-- multiplier and fever flag are re-derived via updateMultiplier so the
	-- invariants currentMultiplier == updateMultiplier(redPegsHitAmount)
	-- and isFever == (currentMultiplier == 100) hold even when a capture is
	-- internally inconsistent. A consistent fever capture keeps its Phase B
	-- bucket activation (updateMultiplier only activates on the
	-- non-fever -> fever transition), so it restores with multiplier 100 and
	-- fever buckets active. Older schema-2 files without the field keep the
	-- pre-fix defaults (0 red pegs, multiplier 1).
	if is_schema_2 and replay_data.redPegsHitAmount ~= nil then
		self.redPegsHitAmount = replay_data.redPegsHitAmount
		self:updateMultiplier()
	end

	self.bonusScore = 0
	self.styleScore = 0
	self.clearQueue = nil
	self.clearTimer = 0
	self.turnPegsHit = {}
	self.scoredThisStep = false
	self.bucket.phase = (replay_data.bucket and replay_data.bucket.phase) or 0
	-- Restore the captured x when the file carries it (post-fix captures):
	-- phase alone leaves x at Bucket.new()'s center until the next update
	-- (forever while fever freezes bucket motion). prev_x = x mirrors the
	-- peg convention so the next interpolation has no first-step jump.
	if replay_data.bucket and replay_data.bucket.x ~= nil then
		self.bucket.x = replay_data.bucket.x
		self.bucket.prev_x = replay_data.bucket.x
	end

	-- Commit the ball registration plan.
	if plan then
		self.live_ball_ids = {}
		self.live_id_by_ball = {}
		self.active_balls = candidate_balls
		for _, entry in ipairs(plan) do
			local b = entry.ball
			local id = entry.id
			if entry.was_auto then
				b.id = id
			end
			self.used_ball_ids[id] = true
			self.live_ball_ids[id] = b
			self.live_id_by_ball[b] = id
		end
		self.next_ball_id = new_next
	end

	-- Active-shot identity: the replay is a shot already in progress, so it
	-- must not run under shot_id == 0. No ball_launched event is staged.
	if #self.active_balls > 0 then
		self.shot_id = self.shot_id + 1
		self.shot_initial_step = self.sim_step_id + 1
		self.shot_end_reason = nil
		self.last_removal_reason = nil
		self.styleShots:reset_shot()
		self.ballState:reset_shot()
		self.slideInversion:reset_shot()
		if self.retain_shot_timeline then
			self.current_shot_timeline = {}
		end
	end

	if self.callbacks.onHUDRefresh then self.callbacks.onHUDRefresh(self) end
end

-- ===========================================================================
-- Authoritative peg-hit reduction (post-physics)
-- ===========================================================================

-- Contact kinds whose raw peg contact may produce first-hit scoring. This
-- preserves the exact pre-event-pipeline behavior (verified against git
-- history): swept impacts, non-deflecting grazes, discrete overlap pop-outs,
-- AND pure end-of-step depenetration cleanups all lit up pegs before Phase 1
-- (the old physics hit-callback fired for all four sites).
local SCORING_CONTACT_KINDS = {
	sweep = true,
	graze = true,
	overlap = true,
	depenetrate = true,
}

-- The single reducer predicate: may this raw peg contact produce first-hit
-- scoring? A contact scores iff:
--   * it is a ball_contacted_peg event,
--   * its contact kind is scoring-eligible (see above),
--   * the referenced peg still exists in the world, and
--   * the peg has not already been hit (first-hit only; multiple contacts
--     with the same peg in one step produce exactly one peg_scored — the
--     first contact in raw order).
--
-- reducePegContacts layers a second, coarser rule on top for zero-gap line
-- seams: simultaneous (ball, line, CCD iteration) contacts on adjacent line
-- indices collapse to the lowest line index (see reducePegContacts).
function Engine:contactCanScore(ev, peg)
	if ev.type ~= "ball_contacted_peg" then return false end
	if not SCORING_CONTACT_KINDS[ev.contact_kind] then return false end
	if not peg then return false end
	if peg.hit then return false end
	return true
end

-- Apply first-hit scoring to a peg and buffer a peg_scored derived event.
function Engine:scorePeg(peg, ev)
	peg.hit = true
	self.hitCounter = self.hitCounter + 1
	peg.hit_order = self.hitCounter

	if peg.type == "red" then
		self.redPegsHitAmount = self.redPegsHitAmount + 1
		self:updateMultiplier()
	end

	peg.multiplier_at_hit = self.currentMultiplier
	table.insert(self.turnPegsHit, peg)
	self.scoredThisStep = true

	if self.callbacks.onHUDRefresh then self.callbacks.onHUDRefresh(self) end

	-- Buffer the derived peg_scored event (appended after raw seal).
	table.insert(self.buffered_peg_scored, {
		source_sequence = ev.sequence,
		ball_id = ev.ball_id,
		peg_id = peg.original_index,
		peg_type = peg.type,
		peg_shape = peg.shape or "circle",
		contact_kind = ev.contact_kind,
		did_bounce = ev.did_bounce,
		iteration = ev.iteration,
		line = peg.line and {
			id = peg.line.id,
			index = peg.line.index,
			count = peg.line.count,
			closed = peg.line.closed,
			gap = peg.line.gap,
		} or nil,
		impact_x = ev.impact_x,
		impact_y = ev.impact_y,
		hit_order = peg.hit_order,
		multiplier_at_hit = peg.multiplier_at_hit,
		peg_value = Peg.value(peg),
	})

	if peg.type == "green" then
		-- Green powers activate during the controlled reduction phase (outside
		-- the CCD loop). Spawned balls are staged and begin physics next step.
		local specs = Powers.activate(peg)
		self:stagePowerSpawns(specs)
	elseif peg.type == "purple" then
		PegColors.on_purple_peg_hit(peg)
	end

	if self.callbacks.onPegHit then self.callbacks.onPegHit(self, peg) end
end

-- Reduce ordered raw peg-contact events in source order. This replaces the
-- immediate physics callback's authoritative gameplay responsibilities.
--
-- Shared-boundary reduction: zero-gap line pegs touch at exact seams, and a
-- single ball step may report contacts against both members of one seam
-- (resolved winner + graze in the same CCD iteration, or paired
-- end-of-step depenetration reports at iteration 0). Those contacts are one
-- physical crossing: simultaneous contacts from the same ball, line, and
-- CCD iteration whose line indices are adjacent neighbors collapse to a
-- single score using the lower line index as the total-order winner.
function Engine:reducePegContacts()
	self.buffered_peg_scored = {}
	self.pending_spawn_specs = {}

	-- Phase 1: collect all eligible raw contacts in raw order. Eligibility
	-- depends only on contactCanScore (peg exists, kind scores, peg not yet
	-- hit). Collecting every contact — not just the first per peg — lets a
	-- peg whose earliest contact is seam-suppressed still score from a later
	-- independent contact in the same step.
	local candidates = {}
	for _, ev in ipairs(self.events:raw()) do
		if ev.type == "ball_contacted_peg" then
			local peg = self.peg_by_id[ev.peg_id]
			if peg and self:contactCanScore(ev, peg) then
				table.insert(candidates, { ev = ev, peg = peg })
			end
		end
	end

	-- Phase 2: collapse simultaneous (ball, line, iteration) adjacent-index
	-- contacts to the lowest line index. Only zero-gap line pegs can share a
	-- physical boundary, but adjacency (including the closed seam) decides.
	-- Deduplicate per (group, peg) keeping the earliest TOI so a peg with
	-- multiple contacts in one iteration contributes one group member and
	-- cannot break the contiguous-run detection.
	local suppressed = {}
	local keys = {}
	local groups = {}
	for _, c in ipairs(candidates) do
		local line = c.peg.line
		local iteration = c.ev.iteration
		-- Only zero-gap neighbors share an exact boundary, so only they can
		-- collapse. Positive-gap members are distinct physical contacts.
		if line and iteration ~= nil and line.gap == 0 then
			local key = c.ev.ball_id .. "|" .. line.id .. "|" .. tostring(iteration)
			local group = groups[key]
			if not group then
				group = { by_peg = {} }
				groups[key] = group
				table.insert(keys, key)
			end
			local existing = group.by_peg[c.peg]
			if not existing then
				group.by_peg[c.peg] = c
				table.insert(group, c)
			elseif (c.ev.toi or 0) < (existing.ev.toi or 0) then
				-- Keep the earliest TOI for this peg within the group.
				group.by_peg[c.peg] = c
				for i, member in ipairs(group) do
					if member == existing then
						group[i] = c
						break
					end
				end
			end
		end
	end
	for _, key in ipairs(keys) do
		local group = groups[key]
		local n = #group
		if n >= 2 then
			table.sort(group, function(a, b)
				return a.peg.line.index < b.peg.line.index
			end)
			-- A shared boundary is a single event in both space and time.
			-- Contacts in one CCD iteration at different TOIs are sequential
			-- crossings (a slide grazing one peg after another) and must not
			-- collapse; the suppressed peg would be lost from the score.
			local toi_min, toi_max
			for _, c in ipairs(group) do
				local toi = c.ev.toi or 0
				if toi_min == nil or toi < toi_min then toi_min = toi end
				if toi_max == nil or toi > toi_max then toi_max = toi end
			end
			local first_line = group[1].peg.line
			-- The group is one contiguous run if every member except the
			-- lowest links to a member at index+1. All such links are
			-- consecutive in sorted order; on a closed line the count->1
			-- seam is the one link that is not (degenerate count == 2 rings
			-- already link 1->2 in sorted order, so skip the seam there).
			local links = 0
			for i = 2, n do
				if group[i].peg.line.index == group[i - 1].peg.line.index + 1 then
					links = links + 1
				end
			end
			if first_line.closed and first_line.count >= 3
				and group[1].peg.line.index == 1
				and group[n].peg.line.index == first_line.count then
				links = links + 1
			end
			if links == n - 1 and (toi_max - toi_min) <= SEAM_TOI_EPSILON then
				-- Lowest line index wins; the rest of the group is one score.
				local drop = suppressed[key]
				if not drop then
					drop = {}
					suppressed[key] = drop
				end
				for i = 2, n do
					drop[group[i].peg] = true
				end
			end
		end
	end

	-- Phase 3: score each peg at most once, using its first candidate in raw
	-- order that is not suppressed. Scoring side effects (such as purple
	-- recolor) keep their deterministic interleaving. A peg whose first
	-- candidate was suppressed remains eligible for a later non-suppressed
	-- contact in this same step.
	local scored = {}
	for _, c in ipairs(candidates) do
		local peg = c.peg
		if not scored[peg] then
			local line = peg.line
			local iteration = c.ev.iteration
			local blocked = false
			if line and iteration ~= nil then
				local drop = suppressed[c.ev.ball_id .. "|" .. line.id .. "|" .. tostring(iteration)]
				blocked = drop ~= nil and drop[peg] == true
			end
			if not blocked then
				self:scorePeg(peg, c.ev)
				scored[peg] = true
			end
		end
	end
end

-- ===========================================================================
-- Clearing cascade (existing behavior preserved)
-- ===========================================================================

function Engine:startClearing(isEndOfTurn)
	local lit = {}
	for _, peg in ipairs(self.pegs) do
		if peg.hit then
			table.insert(lit, peg)
		end
	end
	table.sort(lit, function(a, b) return a.hit_order < b.hit_order end)
	self.clearQueue = lit
	self.clearTimer = 0
	self.clearingIsEndOfTurn = isEndOfTurn
end

-- Remove one peg from every board collection. Shared by the end-of-turn
-- clearing cascade and the slide-inversion valley removal. The peg's score
-- (turnPegsHit) is intentionally untouched.
function Engine:removePeg(peg)
	for i, p in ipairs(self.pegs) do
		if p == peg then
			table.remove(self.pegs, i)
			break
		end
	end
	PegColors.on_peg_removed(peg)
	self.peg_by_id[peg.original_index] = nil
	if not peg.shape or peg.shape == "circle" then
		for i, p in ipairs(self.circle_pegs) do
			if p == peg then table.remove(self.circle_pegs, i) break end
		end
	elseif peg.shape == "rectangle" then
		for i, p in ipairs(self.rect_pegs) do
			if p == peg then table.remove(self.rect_pegs, i) break end
		end
	elseif peg.shape == "annular" then
		for i, p in ipairs(self.annular_pegs) do
			if p == peg then table.remove(self.annular_pegs, i) break end
		end
	end
end

function Engine:updateClearing(dt)
	self.clearTimer = self.clearTimer + dt
	while #self.clearQueue > 0 and self.clearTimer >= Config.peg_vanish_interval do
		self.clearTimer = self.clearTimer - Config.peg_vanish_interval
		local peg = table.remove(self.clearQueue, 1)
		self:removePeg(peg)
	end

	if #self.clearQueue == 0 then
		self.clearQueue = nil
		if self.clearingIsEndOfTurn then
			-- End-of-turn: the shot is over. Defer onTurnEnd to the finalize
			-- phase so shot_completed is emitted first.
			self.shot_end_pending = true
		else
			-- Mid-turn clear: reset ball-state timers so the ball can play on.
			self.ballState:reset_timers()
		end
	end
end

-- ===========================================================================
-- Gameplay command application (explicit Engine phase)
-- ===========================================================================

function Engine:applyCommands()
	for _, cmd in ipairs(self.commands:all()) do
		-- Every processed command is journaled with a stable scalar status
		-- (see GameplayCommands): "applied" when it changed authoritative
		-- state, "ignored_duplicate" when it was an idempotent no-op.
		local status = "applied"
		if cmd.type == "award_style_points" then
			self.styleScore = self.styleScore + (cmd.points or 0)
			self.events:emit_derived("style_awarded", {
				ball_id = cmd.ball_id,
				style = cmd.style,
				points = cmd.points,
				distance = cmd.distance,
				peg_id = cmd.peg_id,
				line_id = cmd.line_id,
				source_sequences = cmd.source_sequences,
			})
			if self.callbacks.onHUDRefresh then self.callbacks.onHUDRefresh(self) end
			-- Deferred presentation notification: fired only AFTER the award
			-- has been authoritatively applied. The award table is a fresh
			-- copy: a presentation callback can never mutate the journal.
			if self.callbacks.onStyleShot then
				local seqs = nil
				if cmd.source_sequences then
					seqs = {}
					for i, s in ipairs(cmd.source_sequences) do seqs[i] = s end
				end
				self.callbacks.onStyleShot(self, {
					ball_id = cmd.ball_id,
					style = cmd.style,
					points = cmd.points,
					distance = cmd.distance,
					peg_id = cmd.peg_id,
					line_id = cmd.line_id,
					source_sequences = seqs,
				})
			end
		elseif cmd.type == "start_midturn_clearing" then
			-- Idempotent: clearing initializes at most once per step; further
			-- requests are journaled as ignored duplicates.
			if not self.clearQueue and not self._midturn_clear_started then
				self._midturn_clear_started = true
				local hasHitPegs = false
				for _, peg in ipairs(self.pegs) do
					if peg.hit then hasHitPegs = true break end
				end
				if hasHitPegs then
					self:startClearing(false)
				else
					-- No hit pegs: just reset ball-state timers (preserves
					-- existing behavior of clearing the stall condition).
					self.ballState:reset_timers()
				end
			else
				status = "ignored_duplicate"
			end
		elseif cmd.type == "remove_slide_pegs" then
			-- Valley removal: drop the lowest already-hit peg(s) of the
			-- sliding line from the board. Idempotent: ids already gone are
			-- skipped and the command is a no-op when none remain.
			local removed = 0
			for _, peg_id in ipairs(cmd.peg_ids or {}) do
				local peg = self.peg_by_id[peg_id]
				if peg then
					self:removePeg(peg)
					removed = removed + 1
					self.events:emit_derived("slide_peg_removed", {
						ball_id = cmd.ball_id,
						line_id = cmd.line_id,
						peg_id = peg_id,
						reason = cmd.reason,
					})
				end
			end
			if removed == 0 then
				status = "ignored_duplicate"
			end
		end
		self.commands:record_applied(cmd, status)
	end
	self._midturn_clear_started = nil
end

-- ===========================================================================
-- Rendering interpolation state (unchanged)
-- ===========================================================================

function Engine:savePreviousState()
	for _, peg in ipairs(self.pegs) do
		peg.prev_x = peg.x
		peg.prev_y = peg.y
		if peg.shape == "rectangle" then
			peg.prev_angle = peg.angle
		elseif peg.shape == "annular" then
			peg.prev_angle = peg.angle or 0
		end
	end
	for _, b in ipairs(self.active_balls) do
		b.prev_x = b.x
		b.prev_y = b.y
	end
	if self.bucket then
		self.bucket.prev_x = self.bucket.x
	end
end

-- ===========================================================================
-- Fixed-step simulation (explicit authoritative phase order)
-- ===========================================================================
--
-- Final actual order:
--  1. Begin GameplayEvents/Commands for sim_step_id + shot_id (flush staged).
--  2. Register any unIDed active balls (covers all entry paths).
--  3. Compute time_step (right-click circuit speedup) and ultra-fever check.
--  4. Bucket motion (unless fever).
--  5. Clearing early path -> updateClearing -> finalize.
--  6. Circuits update.
--  7. Physics.update -> raw collision events (observational; no peg.hit).
--  8. Stamp draw_path path_step.
--  9. If not all balls launched -> finalize (no bucket resolution this step).
-- 10. Reduce raw peg contacts (first-hit scoring, multiplier, fever, green
--     powers staged), buffer peg_scored.
-- 11. Bucket / fever resolution -> raw bucket/fever events + mode callbacks.
-- 12. Fall-out detection -> raw ball_fell_out.
-- 13. Remove balls in stable order; notify BallState.
-- 14. Append power-spawned balls (created during reduction) to active_balls.
-- 15. Shot-end detection (all balls gone).
-- 16. Seal raw events.
-- 17. Append buffered peg_scored derived events in source order.
-- 18. StyleShots (push award_style_points commands).
-- 19. BallState (derived ball_became_idle/reactivated/all_idle/no_score_timeout_reached +
--     push start_midturn_clearing).
-- 20. Apply gameplay commands in deterministic order (style -> score, midturn
--     clear); emit style_awarded derived events.
-- 21. Generate shot-lifecycle derived events (shot_completed) if the shot
--     ended this step.
-- 22. Capture authoritative post-command simulation snapshot.
-- 23. Finalize step record (optional timeline retention + trace export).
-- 24. Notify presentation/external onStepFinalized callback (read-only).
-- 25. If shot ended, fire onTurnEnd (which may start the next shot) or
--     onAllBallsDepleted skip behavior.
-- 26. Finish/clear per-step working buffers.
--
-- Note: shot_completed (step 21) is generated AFTER command application so
-- its totals reflect the final authoritative score components. This deviates
-- from the spec's nominal 17-before-18 ordering, documented here.
-- ===========================================================================

function Engine:stepSimulation(dt)
	self.scoredThisStep = false
	self.shot_end_pending = false

	-- (1) Begin gameplay event pipeline for this fixed step.
	self.events:begin_step(self.sim_step_id, self.shot_id)
	self.commands:begin_step(self.sim_step_id, self.shot_id)

	-- (2) Register any active balls lacking stable IDs.
	for _, b in ipairs(self.active_balls) do
		self:registerBall(b)
	end

	-- (3) Compute time_step and ultra-fever.
	local ball_active = false
	local has_unlaunched = false
	for _, b in ipairs(self.active_balls) do
		if b.launched then ball_active = true else has_unlaunched = true end
	end

	local time_step = dt
	if has_unlaunched and not ball_active and love.mouse.isDown(2) then
		time_step = dt * (Config.circuit_speedup_multiplier or 5)
	end

	if self.isFever then
		local isUltra = true
		for _, peg in ipairs(self.pegs) do
			if not peg.hit then isUltra = false break end
		end
		if isUltra then
			for _, b in ipairs(self.feverBuckets.buckets) do
				b.value = 100000
			end
		end
	end

	-- (4) Bucket motion (unless fever).
	if not self.isFever then
		Bucket.update(self.bucket, time_step)
	end

	-- (5) Clearing early path.
	if self.clearQueue then
		self:updateClearing(dt)
		goto finalize
	end

	-- Steps 6-15 run inside a scoped block so their locals are not in scope
	-- at the `finalize` label (Lua forbids goto into a local's scope).
	do
		-- (6) Circuits update.
		Circuits.update(self.pegs, self.level_circuits, time_step)

		-- (7) Physics -> raw collision events (observational).
		local extras = self.isFever and self.feverBuckets.dividers or nil
		Physics.update(self.active_balls, self.circle_pegs, self.rect_pegs,
			self.annular_pegs, dt, extras, self.events)

		-- (8) Stamp draw_path path_step.
		for _, b in ipairs(self.active_balls) do
			if b.draw_path then
				b.draw_path.path_step = self.sim_step_id
			end
		end

		-- (9) If not all launched, no bucket resolution this step.
		local all_launched = true
		for _, b in ipairs(self.active_balls) do
			if not b.launched then all_launched = false break end
		end
		if not all_launched then
			goto finalize
		end

		-- (10) Reduce raw peg contacts (authoritative first-hit scoring).
		self:reducePegContacts()

	-- (11) Bucket / fever resolution + raw events + mode callbacks.
	local remaining_balls = {}
	for _, b in ipairs(self.active_balls) do
		local remove_ball = false
		local caught = false

		if self.isFever then
			local result, value = FeverBuckets.resolve(self.feverBuckets, b)
			if result == "caught" and not b.scoredFever then
				self.bonusScore = self.bonusScore + value
				b.scoredFever = true
				self.events:emit_raw("fever_bucket_caught_ball", {
					ball_id = b.id,
					x = b.x, y = b.y,
					incoming_vx = b.vx, incoming_vy = b.vy,
					outgoing_vx = b.vx, outgoing_vy = b.vy,
					value = value,
				})
				if self.callbacks.onHUDRefresh then self.callbacks.onHUDRefresh(self) end
				if self.callbacks.onFeverCatch then
					self.callbacks.onFeverCatch(self, b, value)
				end
			end
		else
			local in_vx, in_vy = b.vx, b.vy
			local result = Bucket.resolve(self.bucket, b)
			local out_vx, out_vy = b.vx, b.vy
			if result == "caught" then
				caught = true
				remove_ball = true
				self.events:emit_raw("bucket_caught_ball", {
					ball_id = b.id,
					x = b.x, y = b.y,
					incoming_vx = in_vx, incoming_vy = in_vy,
					outgoing_vx = out_vx, outgoing_vy = out_vy,
					bucket_x = self.bucket.x,
				})
				if self.callbacks.onBucketCatch then
					self.callbacks.onBucketCatch(self, b)
				end
				if self.callbacks.onHUDRefresh then self.callbacks.onHUDRefresh(self) end
			elseif result == "bounced" then
				self.events:emit_raw("bucket_bounced_ball", {
					ball_id = b.id,
					x = b.x, y = b.y,
					incoming_vx = in_vx, incoming_vy = in_vy,
					outgoing_vx = out_vx, outgoing_vy = out_vy,
					bucket_x = self.bucket.x,
				})
			end
		end

		-- (12) Fall-out detection (a caught ball must not also emit fell_out).
		if not caught and b.y - b.radius > LevelManager.virtual_height + Config.fall_out_margin then
			remove_ball = true
			self.events:emit_raw("ball_fell_out", {
				ball_id = b.id,
				x = b.x, y = b.y,
				reason = "open_floor",
			})
		end

		if remove_ball then
			-- (13) Ball removal: track reason + notify BallState + free live ID.
			if caught then
				self.last_removal_reason = "bucket_caught"
			else
				self.last_removal_reason = "fell_out"
			end
			self.ballState:on_ball_removed(b.id)
			self.slideInversion:on_ball_removed(b.id)
			self:unregisterBall(b)
		else
			table.insert(remaining_balls, b)
		end
	end
	self.active_balls = remaining_balls

	-- (14) Append power-spawned balls (created during reduction). They begin
	-- physics on the following fixed step.
	if self.pending_spawn_specs then
		for _, spec in ipairs(self.pending_spawn_specs) do
			local nb = Ball.new(spec.x, spec.y)
			nb.launched = true
			nb.vx = spec.vx
			nb.vy = spec.vy
			self:registerBall(nb)
			table.insert(self.active_balls, nb)
			self.ballState:on_ball_spawned()
			self.events:emit_raw("ball_spawned", {
				ball_id = nb.id,
				source = "green_power",
				x = nb.x, y = nb.y,
				vx = nb.vx, vy = nb.vy,
			})
		end
		self.pending_spawn_specs = nil
	end

	-- (15) Shot-end detection.
	if #self.active_balls == 0 then
		local skip_clearing = false
		if self.callbacks.onAllBallsDepleted then
			skip_clearing = self.callbacks.onAllBallsDepleted(self)
		end
		if not skip_clearing then
			self:startClearing(true)
		else
			-- Mode handled depletion itself; the shot ends now.
			self.shot_end_reason = self.last_removal_reason or "all_balls_removed"
			self.shot_end_pending = true
		end
	end
	end -- close steps 6-15 scoped block

	::finalize::
	self:finalizeStep(dt)
end

-- Finalize the fixed step: seal raw, run processors, apply commands, capture
-- snapshot, emit shot completion, retain/trace, notify presentation. Every
-- code path (including early returns) reaches here.
function Engine:finalizeStep(dt)
	-- (16) Seal raw events.
	self.events:seal_raw()

	-- (17) Append buffered peg_scored derived events in source order.
	if self.buffered_peg_scored then
		for _, ps in ipairs(self.buffered_peg_scored) do
			self.events:emit_derived("peg_scored", ps)
		end
		self.buffered_peg_scored = nil
	end

	-- (18) StyleShots -> award_style_points commands.
	self.styleShots:process_step(self.events, self.commands, {
		virtual_width = LevelManager.virtual_width,
	})

	-- (18b) SlideInversion -> remove_slide_pegs command. Runs after
	-- peg_scored events exist and before commands are applied. Paused while a
	-- clearing cascade is active (the cascade already removes hit pegs).
	if not self.clearQueue then
		self.slideInversion:process_step(self.events, self.commands,
			self.active_balls, dt)
	end

	-- (19) BallState -> derived events + start_midturn_clearing command.
	-- Skipped while a clearing cascade is active: stall/idle/no-score timers
	-- are paused during clearing (preserves pre-pipeline behavior, where the
	-- clearing early-return prevented timer accumulation).
	if not self.clearQueue then
		self.ballState:process_step(self.events, self.commands, self.active_balls, dt)
	end

	-- (20) Apply gameplay commands in deterministic order.
	self:applyCommands()

	-- (21) Shot-lifecycle derived events.
	if self.shot_end_pending then
		self.shot_end_pending = false
		self:emitShotCompleted()
	end

	-- (22)+(23) Step record: only built when a consumer exists (timeline
	-- retention, canonical trace, or an onStepFinalized callback). Events
	-- are detached from the working journal via snapshot() — the retained
	-- record does not alias the journal's per-step arrays (raw_events /
	-- derived_events). Ordinary live gameplay performs no event-snapshot
	-- deep copies here; internal processors continue to use the cheap
	-- borrowed views from raw() / derived().
	local want_record = (self.retain_shot_timeline and self.current_shot_timeline ~= nil)
		or self.trace_exporter ~= nil
		or self.callbacks.onStepFinalized ~= nil
	local step_record = nil
	if want_record then
		local snapshot = nil
		if self.trace_exporter or self.retain_shot_timeline then
			snapshot = SimulationSnapshot.capture(self)
		end
		local event_snapshot = self.events:snapshot()
		self.shot_final_step = self.sim_step_id
		step_record = {
			step = self.sim_step_id,
			shot_id = self.shot_id,
			raw_events = event_snapshot.raw,
			derived_events = event_snapshot.derived,
			requested_commands = self.commands:snapshot(),
			applied_commands = self.commands:applied_snapshot(),
			snapshot = snapshot,
		}
		if self.retain_shot_timeline and self.current_shot_timeline then
			table.insert(self.current_shot_timeline, step_record)
		end
		if self.trace_exporter then
			GameplayTraceExporter.export_step(step_record)
		end
	else
		self.shot_final_step = self.sim_step_id
	end
	-- Legacy trace exporter (per-frame ball/peg/bucket snapshots).
	if TraceExporter.file then
		TraceExporter.record_frame(self.active_balls, self.pegs, self.bucket)
	end

	-- (24) Notify presentation. The callback receives an independent
	-- plain-data copy of the completed step record so callback mutation
	-- cannot affect the retained timeline, previously written trace output,
	-- or the working journal. The callback may continue to access Engine
	-- through the first argument (self) — this task only fixes ownership
	-- of the step_record value.
	if self.callbacks.onStepFinalized and step_record then
		self.callbacks.onStepFinalized(self, Exportable.copy(step_record, "onStepFinalized copy"))
	end

	-- (25) If the shot ended, fire onTurnEnd (may start the next shot).
	if self.shot_end_reason ~= nil and self.shot_end_reason ~= "__handled" then
		local reason = self.shot_end_reason
		self.shot_end_reason = "__handled"
		-- Finalize the current shot timeline.
		self:finalizeShotTimeline(reason)
		if self.callbacks.onTurnEnd then
			self.callbacks.onTurnEnd(self)
		end
	end

	-- (26) Finish/clear per-step working buffers.
	self.events:finish_step()
	self.commands:clear()
end

-- Emit the shot_completed derived event with final score components.
--
-- This runs AFTER applyCommands (phase 20), so every style award requested
-- this step — including one earned on the shot's final step — is already
-- included in self.styleScore. The reported components must equal the
-- authoritative Engine state exactly: no pending-command rescanning (that
-- would double-count this step's awards).
function Engine:emitShotCompleted()
	local peg_score = self:getTurnPegScore()
	local bonus_score = self.bonusScore
	local style_score = self.styleScore
	local total_score = peg_score + bonus_score + style_score

	local reason = self.shot_end_reason
	if reason == nil or reason == "__handled" then
		reason = self.last_removal_reason or "all_balls_removed"
		self.shot_end_reason = reason
	end

	self.events:emit_derived("shot_completed", {
		completion_reason = reason,
		initial_step = self.shot_initial_step,
		final_step = self.sim_step_id,
		shot_id = self.shot_id,
		peg_score = peg_score,
		bonus_score = bonus_score,
		style_score = style_score,
		total_score = total_score,
	})
end

-- Finalize the retained shot timeline with metadata.
function Engine:finalizeShotTimeline(reason)
	if not self.retain_shot_timeline then return end
	if self.current_shot_timeline then
		self.shot_timelines[self.shot_id] = {
			shot_id = self.shot_id,
			initial_step = self.shot_initial_step,
			final_step = self.shot_final_step,
			completion_reason = reason,
			step_count = #self.current_shot_timeline,
			steps = self.current_shot_timeline,
		}
	end
	self.current_shot_timeline = nil
end

-- ===========================================================================
-- Main update loop (accumulator -> fixed steps)
-- ===========================================================================

function Engine:update(dt)
	if self.is_halted then return end

	Perf.beginUpdate()
	local active_count = 0
	local unlaunched_ball = nil
	for _, b in ipairs(self.active_balls) do
		if b.launched then active_count = active_count + 1 else unlaunched_ball = b end
	end
	Perf.setActiveBalls(active_count)

	self.accumulator = self.accumulator + dt
	while self.accumulator >= Config.fixed_dt do
		self:savePreviousState()
		self.sim_step_id = self.sim_step_id + 1
		self.steps_since_last_draw = self.steps_since_last_draw + 1
		ContactEvents.set_step(self.sim_step_id)
		self:stepSimulation(Config.fixed_dt)
		self.accumulator = self.accumulator - Config.fixed_dt
	end

	FeverBuckets.update(self.feverBuckets, dt)

	if unlaunched_ball and not self.clearQueue and not self.is_halted then
		if love.keyboard.isDown("left") then
			self.key_hold_time_left = self.key_hold_time_left + dt
		else
			self.key_hold_time_left = 0
		end

		if love.keyboard.isDown("right") then
			self.key_hold_time_right = self.key_hold_time_right + dt
		else
			self.key_hold_time_right = 0
		end

		local moved = false
		if self.key_hold_time_left > 0.2 then
			self.current_aim_angle = self.current_aim_angle + Config.aim_fine_adjust_speed * dt
			moved = true
		elseif self.key_hold_time_right > 0.2 then
			self.current_aim_angle = self.current_aim_angle - Config.aim_fine_adjust_speed * dt
			moved = true
		end
		if moved then
			local limit = Config.aim_angle_limit
			local mid = math.pi / 2
			self.current_aim_angle = math.max(mid - limit, math.min(mid + limit, self.current_aim_angle))
		end
	end

	Perf.endUpdate()
end

function Engine:draw()
	love.graphics.setColor(Config.background_color)
	love.graphics.rectangle("fill", 0, 0, LevelManager.virtual_width, LevelManager.virtual_height)

	local unlaunched_ball = nil
	for _, b in ipairs(self.active_balls) do
		if not b.launched then unlaunched_ball = b break end
	end

	if unlaunched_ball and not self.clearQueue then
		local effective_angle = Physics.getSnappedAimAngle(self.current_aim_angle)
		local vx = math.cos(effective_angle) * Config.launch_speed
		local vy = math.sin(effective_angle) * Config.launch_speed
		love.graphics.setColor(1, 1, 1, 0.4)
		local tx, ty = unlaunched_ball.x, unlaunched_ball.y
		local tvx, tvy = vx, vy
		local step = 2 / 100
		local gravity_step = Config.gravity * step
		for i = 1, 10 do
			tx = tx + tvx * step
			ty = ty + tvy * step
			tvy = tvy + gravity_step
			love.graphics.circle("fill", tx, ty, 2)
		end
	end

	local alpha = self.accumulator / Config.fixed_dt

	self.render_frame_id = self.render_frame_id + 1
	ContactEvents.begin_frame(self, alpha)
	self.steps_since_last_draw = 0

	for _, peg in ipairs(self.pegs) do
		Peg.draw(peg, alpha)
	end

	if self.isFever then
		FeverBuckets.draw(self.feverBuckets)
	else
		Bucket.draw(self.bucket, alpha)
	end

	for _, b in ipairs(self.active_balls) do
		Ball.draw(b, alpha)
	end

	ImpactDebug.drawMarkers()

	ContactEvents.end_frame()
end

function Engine:launchBalls()
	if self.clearQueue or self.is_halted then return end
	local has_unlaunched = false
	for _, b in ipairs(self.active_balls) do
		if not b.launched then has_unlaunched = true break end
	end
	if not has_unlaunched then return end

	local can_launch = true
	if self.callbacks.onLaunch then
		can_launch = self.callbacks.onLaunch(self)
	end

	if not can_launch then return end

	-- New shot: increment shot_id (identifies one launched shot, including
	-- all balls created as part of it, e.g. multiball).
	self.shot_id = self.shot_id + 1
	self.shot_initial_step = self.sim_step_id + 1
	self.shot_final_step = self.sim_step_id
	self.shot_end_reason = nil
	self.last_removal_reason = nil
	self.styleShots:reset_shot()
	self.ballState:reset_shot()
	self.slideInversion:reset_shot()
	if self.retain_shot_timeline then
		self.current_shot_timeline = {}
	end

	for _, b in ipairs(self.active_balls) do
		if not b.launched then
			b.launched = true
			local effective_angle = Physics.getSnappedAimAngle(self.current_aim_angle)
			b.vx = math.cos(effective_angle) * Config.launch_speed
			b.vy = math.sin(effective_angle) * Config.launch_speed
			-- Stage the ball_launched raw event (flushed at next fixed step).
			self.events:stage("ball_launched", {
				ball_id = b.id,
				x = b.x, y = b.y,
				vx = b.vx, vy = b.vy,
			})
		end
	end

	-- Serialize at launch time: pegs/bucket/active_balls are live tables that
	-- mutate during the shot, so a later save must reuse this string rather
	-- than re-serializing the (now post-shot) state.
	local replay_lua = Replay.serialize({
		level_name = self.level_name,
		isFever = self.isFever,
		hitCounter = self.hitCounter,
		redPegsHitAmount = self.redPegsHitAmount,
		currentMultiplier = self.currentMultiplier,
		pegs = self.pegs,
		bucket = self.bucket,
		balls = self.active_balls
	})
	-- Backward-compatible rolling capture used by `make trace`.
	Replay.write(self.last_shot_replay_path, replay_lua)
	self.last_shot_replay_lua = replay_lua

	if self.callbacks.onHUDRefresh then self.callbacks.onHUDRefresh(self) end
end

-- Explicitly save the most recent shot to the named replay library. `name`
-- is an optional label appended after the capture timestamp. Returns the
-- saved path, or nil plus an error message.
function Engine:saveLastShotReplay(name)
	if not self.last_shot_replay_lua then
		return nil, "no shot has been launched yet"
	end
	return ReplayLibrary.saveSerialized(self.last_shot_replay_lua, name)
end

function Engine:mousepressed(x, y, button)
	if button == 1 and not self.clearQueue and not self.is_halted then
		self:launchBalls()
	end
end

function Engine:mousemoved(x, y, dx, dy)
	if self.is_halted then return end
	local wx, wy = Screen.to_world(x, y)
	local unlaunched_ball = nil
	for _, b in ipairs(self.active_balls) do
		if not b.launched then unlaunched_ball = b break end
	end
	if unlaunched_ball and not self.clearQueue then
		local vx, vy = Physics.getLaunchVelocity(unlaunched_ball.x, unlaunched_ball.y, wx, wy, Config.launch_speed)
		local angle
		if vx == 0 and vy == 0 then
			angle = math.atan2(y - unlaunched_ball.y, x - unlaunched_ball.x)
		else
			angle = math.atan2(vy, vx)
		end

		local limit = Config.aim_angle_limit
		local mid = math.pi / 2

		while angle < mid - math.pi do angle = angle + 2 * math.pi end
		while angle > mid + math.pi do angle = angle - 2 * math.pi end

		self.current_aim_angle = math.max(mid - limit, math.min(mid + limit, angle))
	end
end

function Engine:wheelmoved(x, y)
	if self.is_halted then return end
	local has_unlaunched = false
	for _, b in ipairs(self.active_balls) do
		if not b.launched then has_unlaunched = true break end
	end
	if has_unlaunched and not self.clearQueue then
		self.current_aim_angle = self.current_aim_angle + y * Config.aim_wheel_adjust
		local limit = Config.aim_angle_limit
		local mid = math.pi / 2
		self.current_aim_angle = math.max(mid - limit, math.min(mid + limit, self.current_aim_angle))
	end
end

function Engine:keypressed(key)
	if self.is_halted then return end

	if key == "left" or key == "right" then
		if Config.aim_discretization_steps then
			self.current_aim_angle = Physics.getSnappedAimAngle(self.current_aim_angle)
			local step_size = (2 * Config.aim_angle_limit) / Config.aim_discretization_steps
			if key == "left" then
				self.current_aim_angle = self.current_aim_angle + step_size
			else
				self.current_aim_angle = self.current_aim_angle - step_size
			end
		else
			local step_size = math.rad(0.5)
			if key == "left" then
				self.current_aim_angle = self.current_aim_angle + step_size
			else
				self.current_aim_angle = self.current_aim_angle - step_size
			end
		end
		local limit = Config.aim_angle_limit
		local mid = math.pi / 2
		self.current_aim_angle = math.max(mid - limit, math.min(mid + limit, self.current_aim_angle))
	end

	if key == "return" or key == "kpenter" then
		self:launchBalls()
	end
end

return Engine
