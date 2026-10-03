-- ===========================================================================
-- GameplayCommands: ordered buffer of requested authoritative mutations.
--
-- One instance is owned by each Engine. Processors (peg-hit reduction, style
-- shots, ball state, ...) push commands describing the mutation they want the
-- Engine to apply after all processors finish. The Engine alone applies
-- commands, in deterministic insertion order.
--
-- Command envelope (added automatically):
--   step, shot_id, sequence, type
--
-- Commands contain only stable IDs and scalar/exportable data. Payloads are
-- validated and recursively deep-copied at push time (see exportable.lua), so
-- caller-owned tables (e.g. a `source_sequences` array) are never retained by
-- reference.
--
-- Requested vs applied commands (documented semantics):
--   * `all()` / `snapshot()` expose the REQUESTED commands in push order.
--     Every request remains visible here, including idempotent duplicates.
--   * The APPLIED journal (`applied_snapshot()`) records every command the
--     Engine processed, in processing order, as an independent copy carrying
--     a stable scalar `status`:
--       - "applied"           — the command changed authoritative state
--       - "ignored_duplicate" — the command was an idempotent duplicate and
--                               was intentionally a no-op
--     An ignored duplicate is never described as successfully applied.
-- ===========================================================================

local Exportable = require("src.systems.exportable")

local GameplayCommands = {}
local GameplayCommands_mt = { __index = GameplayCommands }

local function copy_cmd(cmd)
	return Exportable.copy(cmd, "GameplayCommands.copy")
end

function GameplayCommands.new()
	local self = setmetatable({}, GameplayCommands_mt)
	self:reset()
	return self
end

function GameplayCommands:reset()
	self.step_id = 0
	self.shot_id = 0
	self.sequence = 0
	self.commands = {}
	self.applied = {}
end

function GameplayCommands:begin_step(step_id, shot_id)
	self.step_id = step_id
	self.shot_id = shot_id
	self.sequence = 0
	self.commands = {}
	self.applied = {}
end

function GameplayCommands:push(command_type, fields)
	-- Validate/copy FIRST: a rejected payload leaves the buffer untouched.
	local owned = nil
	if fields then
		owned = Exportable.copy(fields,
			"GameplayCommands.push('" .. tostring(command_type) .. "')")
	end
	self.sequence = self.sequence + 1
	local cmd = {
		step = self.step_id,
		shot_id = self.shot_id,
		sequence = self.sequence,
		type = command_type,
	}
	if owned then
		for k, v in pairs(owned) do
			cmd[k] = v
		end
	end
	table.insert(self.commands, cmd)
end

function GameplayCommands:all()
	return self.commands
end

-- Snapshot of the requested commands this step (independent deep copy).
function GameplayCommands:snapshot()
	local out = {}
	for _, c in ipairs(self.commands) do table.insert(out, copy_cmd(c)) end
	return out
end

-- Record that the Engine processed a command. `status` is a stable scalar:
--   "applied"           — the command changed authoritative state
--   "ignored_duplicate" — idempotent duplicate; intentionally a no-op
-- The applied journal stores an independent copy plus the status.
function GameplayCommands:record_applied(cmd, status)
	local rec = copy_cmd(cmd)
	rec.status = status or "applied"
	table.insert(self.applied, rec)
end

-- Snapshot of the applied journal (independent deep copies, with status).
function GameplayCommands:applied_snapshot()
	local out = {}
	for _, c in ipairs(self.applied) do table.insert(out, copy_cmd(c)) end
	return out
end

function GameplayCommands:clear()
	self.commands = {}
	self.applied = {}
end

return GameplayCommands
