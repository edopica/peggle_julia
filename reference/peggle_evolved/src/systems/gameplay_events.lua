-- ===========================================================================
-- GameplayEvents: per-step append-only deterministic gameplay event journal.
--
-- One instance is owned by each Engine. It is the authoritative record of
-- "what happened during this fixed step, and in what order".
--
-- Phases:
--   raw     — objective facts produced during physics/bucket/fall-out. Raw
--             events preserve their original production order and may not be
--             appended after seal_raw().
--   derived — facts derived from raw events by explicit Engine processors
--             (peg_scored, style awards, ball state, shot completion). Derived
--             events are appended in processor-defined deterministic order.
--
-- Envelope (added automatically):
--   schema_version, step, shot_id, sequence (per-step, from 1), phase, type
--
-- Payload ownership:
-- Payloads are validated and recursively deep-copied at stage/emit time
-- (see exportable.lua), so the journal fully owns its stored event tables.
-- Mutating a producer-side table after emit/stage does not affect the
-- journal. Payloads may only contain strings, finite numbers, booleans, nil,
-- and recursively exportable tables — never functions, userdata, threads,
-- NaN, infinities, cyclic tables, or unsupported key types.
--
-- Borrowed internal views:
--   * raw()  — returns the journal-owned internal raw_events array.
--   * derived() — returns the journal-owned internal derived_events array.
--   * all()  — returns a new array whose elements are the journal-owned
--               event tables (raw first, then derived).
-- These are cheap borrowed views for trusted authoritative processors
-- (Physics, Engine reduction, StyleShots, BallState, etc.). Internal
-- consumers MUST NOT mutate existing events or their nested payloads.
-- The system does not defend against intentionally malicious code that
-- reaches through engine.events and mutates internal array contents.
--
-- External / retained boundaries:
-- When a completed event record must outlive the current step or pass
-- outside the authoritative processing pipeline, use snapshot() to obtain
-- a detached deep-copy representation. The retained shot timeline, the
-- gameplay trace exporter, and the onStepFinalized callback all receive
-- detached copies — never direct journal aliases. For the onStepFinalized
-- callback specifically, the Engine creates an additional plain-data copy
-- so callback-side mutation cannot change the retained timeline or
-- previously written trace output.
--
-- Events generated outside an open fixed step (e.g. launch input) are
-- staged and deterministically flushed at the beginning of the next fixed
-- step as raw events, with the step's shot_id.
-- ===========================================================================

local Exportable = require("src.systems.exportable")

local GameplayEvents = {}
local GameplayEvents_mt = { __index = GameplayEvents }

local SCHEMA_VERSION = 1

function GameplayEvents.new()
	local self = setmetatable({}, GameplayEvents_mt)
	self:reset()
	return self
end

function GameplayEvents:reset()
	self.step_id = 0
	self.shot_id = 0
	self.sequence = 0
	self.raw_sealed = false
	self.raw_events = {}
	self.derived_events = {}
	self.staged = {} -- events produced outside an open step
	self.open = false
end

-- Stage an event for deterministic flush at the next begin_step.
-- staged events become raw events of the next step (in staging order).
-- The payload is validated and deep-copied NOW: later mutation of the
-- caller's table cannot affect the staged event.
function GameplayEvents:stage(event_type, fields)
	local owned = nil
	if fields ~= nil then
		owned = Exportable.copy(fields, "GameplayEvents.stage('" .. tostring(event_type) .. "')")
	end
	table.insert(self.staged, { type = event_type, fields = owned })
end

-- Begin a new fixed step. Flushes staged events as raw events first.
function GameplayEvents:begin_step(step_id, shot_id)
	self.step_id = step_id
	self.shot_id = shot_id
	self.sequence = 0
	self.raw_sealed = false
	self.raw_events = {}
	self.derived_events = {}
	self.open = true

	for _, s in ipairs(self.staged) do
		self:emit_raw(s.type, s.fields)
	end
	self.staged = {}
end

-- Append a raw event. Error after seal_raw or outside an open step.
-- The payload is validated and deep-copied into the journal (ownership).
function GameplayEvents:emit_raw(event_type, fields)
	if not self.open then
		error("GameplayEvents: emit_raw('" .. event_type .. "') outside an open step", 2)
	end
	if self.raw_sealed then
		error("GameplayEvents: emit_raw('" .. event_type .. "') after seal_raw", 2)
	end
	-- Validate/copy FIRST: a rejected payload leaves the journal untouched.
	local owned = nil
	if fields then
		owned = Exportable.copy(fields, "GameplayEvents.emit_raw('" .. event_type .. "')")
	end
	self.sequence = self.sequence + 1
	local ev = {
		schema_version = SCHEMA_VERSION,
		step = self.step_id,
		shot_id = self.shot_id,
		sequence = self.sequence,
		phase = "raw",
		type = event_type,
	}
	if owned then
		for k, v in pairs(owned) do
			ev[k] = v
		end
	end
	table.insert(self.raw_events, ev)
end

-- Seal the raw phase. After this, no more raw events may be appended.
function GameplayEvents:seal_raw()
	if not self.open then
		error("GameplayEvents: seal_raw outside an open step", 2)
	end
	self.raw_sealed = true
end

-- Append a derived event. Only valid after seal_raw (raw phase complete).
-- The payload is validated and deep-copied into the journal (ownership).
function GameplayEvents:emit_derived(event_type, fields)
	if not self.open then
		error("GameplayEvents: emit_derived('" .. event_type .. "') outside an open step", 2)
	end
	if not self.raw_sealed then
		error("GameplayEvents: emit_derived('" .. event_type .. "') before seal_raw", 2)
	end
	-- Validate/copy FIRST: a rejected payload leaves the journal untouched.
	local owned = nil
	if fields then
		owned = Exportable.copy(fields, "GameplayEvents.emit_derived('" .. event_type .. "')")
	end
	self.sequence = self.sequence + 1
	local ev = {
		schema_version = SCHEMA_VERSION,
		step = self.step_id,
		shot_id = self.shot_id,
		sequence = self.sequence,
		phase = "derived",
		type = event_type,
	}
	if owned then
		for k, v in pairs(owned) do
			ev[k] = v
		end
	end
	table.insert(self.derived_events, ev)
end

-- All events in order: raw first, then derived.
function GameplayEvents:all()
	local out = {}
	for _, e in ipairs(self.raw_events) do table.insert(out, e) end
	for _, e in ipairs(self.derived_events) do table.insert(out, e) end
	return out
end

function GameplayEvents:raw()
	return self.raw_events
end

function GameplayEvents:derived()
	return self.derived_events
end

-- Detached snapshot of the completed step (raw + derived). Returns an
-- independent deep-copy representation: every event table and nested
-- payload is recursively copied via Exportable.copy. Mutating the returned
-- arrays, events, or any nested payload table affects neither the journal
-- nor previously retained snapshots.
--
-- This is intended for explicit external / retained consumers (timeline
-- capture, gameplay-trace export, callback isolation) — NOT for the
-- ordinary live gameplay path, which uses the cheap borrowed raw() /
-- derived() views.
function GameplayEvents:snapshot()
	local raw_copy = {}
	for i, e in ipairs(self.raw_events) do
		raw_copy[i] = Exportable.copy(e, "GameplayEvents.snapshot(raw)")
	end
	local derived_copy = {}
	for i, e in ipairs(self.derived_events) do
		derived_copy[i] = Exportable.copy(e, "GameplayEvents.snapshot(derived)")
	end
	return {
		schema_version = SCHEMA_VERSION,
		step = self.step_id,
		shot_id = self.shot_id,
		event_count = #self.raw_events + #self.derived_events,
		raw = raw_copy,
		derived = derived_copy,
	}
end

-- Finalize the step. The step is considered complete even if empty.
function GameplayEvents:finish_step()
	self.open = false
end

return GameplayEvents
