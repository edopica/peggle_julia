-- M0 baseline sweep harness.
--
-- Runs the pinned Lua reference (reference/peggle_evolved) headlessly and
-- measures the cost of evaluating every legal aim index from a ready-to-aim
-- decision state with zero additional launch delay.
--
-- Usage (from the repository root):
--   love harness -- --sweep --out results/raw/NAME [options]
--
-- Options:
--   --workload ID        workload id from harness/workloads.lua (default: all)
--   --group NAME         only workloads in this group
--   --stride N           evaluate every Nth aim index (default: 1)
--   --indices LIST       explicit comma-separated aim indices (overrides grid)
--   --max-steps N        fixed-step cap per candidate (default: 3600)
--   --warmup N           untimed warmup candidates per workload (default: 8)
--   --repeat N           timed sweeps of the full grid per workload (default: 1)
--   --check-candidates N determinism spot-check candidates per workload (default: 3)
--   --clearing on|off    continue stepping through end-of-turn clearing (default: off)
--   --no-replay-serialize skip Replay.serialize/write inside launchBalls
--   --no-raw             do not write the per-candidate JSONL file
--   --out PREFIX         output prefix for .candidates.jsonl (raw data)
--   --summary-out PREFIX output prefix for .summary.json (default: --out prefix)
--   --list               list workloads and exit
--   --self-check         validate the grid, print the report, and exit
--
-- Fixture tooling:
--   --search             sweep a level's aim grid and report matching candidates
--                        (requires --level; --match FILTER, --limit N)
--                        filters: style:NAME, pegs:N, reds:N, spawn:N, score:N,
--                                 fever, bucket, completed, spawned
--   --fixtures           capture the reference fixture catalog
--   --list-fixtures      list catalog entries and exit
--   --catalog PATH       fixture catalog (default: fixtures/catalog.lua)
--   --fixtures-out DIR   expected-record output dir (default: fixtures/expected)
--   --fixtures-traces DIR gameplay-trace dir (default: fixtures/traces); check
--                        mode reads reference traces here and never writes
--   --fixtures-snapshots include the full authoritative per-step snapshot in
--                        captured traces (capture mode only; check mode stays
--                        snapshot-free)
--   --id ID              capture only this fixture
--   --check              with --fixtures: verify records and traces match the
--                        re-captured ones; never writes into either corpus dir
--
-- M2 reference captures (real LÖVE RNG + vendored reference engine):
--   --m2-capture         capture RNG sequences, peg-color init, checkpoints
--   --m2-rng             only fixtures/rng/rng_sequences.v1.json
--   --m2-peg-colors      only fixtures/rng/peg_colors.v1.json
--   --m2-checkpoints     only fixtures/checkpoints/*.json
--   --levels LIST        comma-separated static level names (passed by
--                        scripts/capture_m2.sh; discovered from
--                        interchange/files.sha256 when omitted)
--   --rng-out DIR        RNG fixture output dir (default: fixtures/rng)
--   --checkpoints-out DIR checkpoint output dir (default: fixtures/checkpoints)
--   --id ID              RNG sequence filter (seed-N or N) and checkpoint
--                        record id (level or slide.multiball3)
--   --level NAME         level filter for peg-color and checkpoint records
--   --check              re-capture in memory and require byte-identical
--                        canonical records; never writes to the corpus
--
-- Run metadata (reference revision, config hash) is supplied by the caller:
--   --reference-revision, --reference-tree, --config-sha256, --run-id,
--   --host-label

local HARNESS_VERSION = 1

-- ===========================================================================
-- CLI parsing (LÖVE passes game args through the global `arg` table)
-- ===========================================================================
local args = {}
do
  local a = rawget(_G, "arg") or {}
  local i = 1
  while i <= #a do
    local tok = a[i]
    if type(tok) == "string" and tok:sub(1, 2) == "--" then
      local key = tok:sub(3)
      local nxt = a[i + 1]
      if nxt ~= nil and type(nxt) == "string" and nxt:sub(1, 2) ~= "--" then
        args[key] = nxt
        i = i + 1
      else
        args[key] = true
      end
    end
    i = i + 1
  end
end

local function arg_number(key, default)
  local v = args[key]
  if v == nil or v == true then return default end
  local n = tonumber(v)
  if n == nil then
    error("invalid number for --" .. key .. ": " .. tostring(v))
  end
  return n
end

-- ===========================================================================
-- Resolve the vendored reference and add it to the Lua module path
-- ===========================================================================
local source_dir = love.filesystem.getSource()
if source_dir:sub(1, 1) ~= "/" then
  source_dir = love.filesystem.getWorkingDirectory() .. "/" .. source_dir
end
local repo_root = source_dir .. "/.."

local ref_root = args["reference-dir"] or (source_dir .. "/../reference/peggle_evolved")
if ref_root:sub(1, 1) ~= "/" then
  ref_root = love.filesystem.getWorkingDirectory() .. "/" .. ref_root
end
package.path = repo_root .. "/tools/?.lua;" .. ref_root .. "/?.lua;"
  .. ref_root .. "/?/init.lua;" .. package.path

-- ===========================================================================
-- Reference modules
-- ===========================================================================
local Config = require("src.config")
local Engine = require("src.engine.core")
local Physics = require("src.systems.physics")
local LevelManager = require("src.systems.level_manager")
local Ball = require("src.entities.ball")
local Replay = require("src.systems.replay")
local GameplayTraceExporter = require("src.systems.gameplay_trace_exporter")
local JSON = require("tools.json")
local CanonicalJSON = require("canonical_json")

-- The reference only runs presentation code when asked; disable it so the
-- authoritative simulation is measured without rendering side effects.
require("src.systems.contact_events").presentation_enabled = false

if args["no-replay-serialize"] then
  Replay.serialize = function() return "" end
  Replay.write = function() return true end
end

local FIXED_DT = Config.fixed_dt
local MAX_STEPS = arg_number("max-steps", 3600)
local CLEARING = args["clearing"] == "on"
local OUT_PREFIX = (args["out"] ~= true and args["out"]) or nil
local SUMMARY_PREFIX = (args["summary-out"] ~= true and args["summary-out"]) or OUT_PREFIX
local WRITE_RAW = not args["no-raw"]
local PROGRESS_EVERY = arg_number("progress", 200)

-- ===========================================================================
-- Small utilities
-- ===========================================================================
local function now()
  return love.timer.getTime()
end

local function read_text(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function json_escape(s)
  return tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function json_string(s)
  return '"' .. json_escape(s) .. '"'
end

-- Preserve double precision for candidate angles.
local function json_number(v)
  if type(v) == "number" and v == math.floor(v) and math.abs(v) < 9007199254740992 then
    return string.format("%d", v)
  end
  return string.format("%.17g", v)
end

local function percentile(sorted, p)
  if #sorted == 0 then return 0 end
  local rank = math.ceil(p * #sorted)
  if rank < 1 then rank = 1 end
  if rank > #sorted then rank = #sorted end
  return sorted[rank]
end

local function stats_of(values)
  local sorted = {}
  local sum = 0
  for i = 1, #values do
    sorted[i] = values[i]
    sum = sum + values[i]
  end
  table.sort(sorted)
  local n = #sorted
  return {
    count = n,
    sum = sum,
    mean = n > 0 and (sum / n) or 0,
    p50 = percentile(sorted, 0.50),
    p90 = percentile(sorted, 0.90),
    p99 = percentile(sorted, 0.99),
    max = n > 0 and sorted[n] or 0,
  }
end

-- Process age in milliseconds, from /proc (Linux). Falls back to nil.
local function process_age_ms()
  local stat = read_text("/proc/self/stat")
  local uptime = read_text("/proc/uptime")
  if not stat or not uptime then return nil end
  local rest = stat:match("%)%s+(.*)$")
  if not rest then return nil end
  local fields = {}
  for tok in rest:gmatch("%S+") do fields[#fields + 1] = tok end
  -- /proc/self/stat field 22 is starttime; rest starts at field 3.
  local starttime = tonumber(fields[20])
  local up = tonumber(uptime:match("^%S+"))
  if not starttime or not up then return nil end
  local clk_tck = 100 -- Linux x86_64 default; compare with --wall-time-s as a cross-check
  return (up - starttime / clk_tck) * 1000
end

local function rss_kb()
  local status = read_text("/proc/self/status")
  if not status then return nil end
  return tonumber(status:match("VmRSS:%s*(%d+)%s*kB"))
end

local function first_line(path)
  local c = read_text(path)
  if not c then return nil end
  return c:match("^([^\n]*)")
end

local function host_info()
  local cpu_fields = {}
  local cpuinfo = read_text("/proc/cpuinfo")
  if cpuinfo then
    for line in cpuinfo:gmatch("[^\n]+") do
      local k, v = line:match("^([^:]+):%s*(.*)$")
      if k then
        k = k:match("^%s*(.-)%s*$")
        if cpu_fields[k] == nil then cpu_fields[k] = v end
      end
    end
  end
  local mem_total_kb = nil
  local meminfo = read_text("/proc/meminfo")
  if meminfo then
    mem_total_kb = tonumber(meminfo:match("MemTotal:%s*(%d+)%s*kB"))
  end
  local os_name = nil
  local os_release = read_text("/etc/os-release")
  if os_release then
    os_name = os_release:match('PRETTY_NAME="(.-)"')
  end
  local has_jit, jit = pcall(require, "jit")
  local processor_count = 0
  for _ in (cpuinfo or ""):gmatch("processor%s*:") do processor_count = processor_count + 1 end
  return {
    os = os_name or first_line("/etc/os-release") or "unknown",
    kernel = first_line("/proc/version") or "unknown",
    cpu_model = cpu_fields["model name"] or "unknown",
    cpu_processors = processor_count,
    mem_total_kb = mem_total_kb,
    love_version = table.concat({ love.getVersion() }, "."),
    luajit = has_jit and jit and jit.version or nil,
    jit_status = has_jit and jit and jit.status() or nil,
  }
end

-- ===========================================================================
-- Candidate grid: derived from the reference snapping function
-- ===========================================================================
local AIM_STEPS = Config.aim_discretization_steps
if not AIM_STEPS then
  error("reference Config.aim_discretization_steps is nil; the grid cannot be derived")
end
local AIM_LIMIT = Config.aim_angle_limit
local AIM_MID = math.pi / 2
local AIM_MIN = AIM_MID - AIM_LIMIT
local AIM_SPAN = 2 * AIM_LIMIT

local function angle_for_index(i)
  return AIM_MIN + (i / AIM_STEPS) * AIM_SPAN
end

local function validate_grid()
  local mismatches = {}
  for i = 0, AIM_STEPS do
    local a = angle_for_index(i)
    local s = Physics.getSnappedAimAngle(a)
    if s ~= a then
      mismatches[#mismatches + 1] = { index = i, angle = a, snapped = s }
    end
  end
  return {
    steps = AIM_STEPS,
    count = AIM_STEPS + 1,
    min_angle = AIM_MIN,
    max_angle = AIM_MID + AIM_LIMIT,
    identity_checked = true,
    mismatches = #mismatches,
    first_mismatch = mismatches[1],
  }
end

local function build_index_list()
  if args["indices"] and args["indices"] ~= true then
    local list = {}
    for tok in tostring(args["indices"]):gmatch("[^,]+") do
      local i = tonumber(tok)
      if i == nil or i < 0 or i > AIM_STEPS or i ~= math.floor(i) then
        error("invalid aim index: " .. tostring(tok))
      end
      list[#list + 1] = i
    end
    return list
  end
  local stride = arg_number("stride", 1)
  if stride < 1 then stride = 1 end
  local list = {}
  for i = 0, AIM_STEPS, stride do
    list[#list + 1] = i
  end
  if list[#list] ~= AIM_STEPS then
    list[#list + 1] = AIM_STEPS
  end
  return list
end

-- A valid grid has at most a negligible count of snapping mismatches; any
-- mismatch means candidate enumeration is not the game's action space.
local GRID = validate_grid()

-- ===========================================================================
-- Workload catalog
-- ===========================================================================
local ALL_WORKLOADS = (function()
  local chunk, err = loadfile(source_dir .. "/workloads.lua")
  if not chunk then
    error("cannot load harness/workloads.lua: " .. tostring(err))
  end
  return chunk()
end)()

local function selected_workloads()
  local wanted = args["workload"]
  local group = args["group"]
  local out = {}
  for _, w in ipairs(ALL_WORKLOADS) do
    local ok = true
    if wanted and wanted ~= true and wanted ~= "all" and w.id ~= wanted then ok = false end
    if group and group ~= true and w.group ~= group then ok = false end
    if ok then out[#out + 1] = w end
  end
  return out
end

-- ===========================================================================
-- Candidate evaluation
-- ===========================================================================
-- Evaluate one candidate from an identical fresh decision state.
--
-- opts (all optional):
--   max_steps       fixed-step cap (default MAX_STEPS)
--   clearing        continue through end-of-turn clearing (default CLEARING)
--   trace_path      write a canonical gameplay trace (no snapshots by default)
--   trace_snapshot  include per-step snapshots in the trace (default false)
local function run_candidate(workload, index, opts)
  opts = opts or {}
  local max_steps = opts.max_steps or MAX_STEPS
  local clearing = opts.clearing
  if clearing == nil then clearing = CLEARING end
  local trace_path = opts.trace_path
  local angle = angle_for_index(index)
  local style_counts = {}
  local shot_done = false

  local t0 = now()

  local engine = Engine.new({
    onStyleShot = function(_, info)
      if info and info.style then
        style_counts[info.style] = (style_counts[info.style] or 0) + 1
      end
    end,
    onTurnEnd = function()
      shot_done = true
    end,
    onAllBallsDepleted = function()
      -- true ends the shot immediately (bench semantics); false lets the
      -- end-of-turn clearing cascade run to the next ready-to-aim boundary.
      return not clearing
    end,
    onBucketCatch = function(eng)
      eng.bonusScore = eng.bonusScore + Config.bucket_bonus
    end,
    onFeverCatch = function() end,
  })
  engine.headless = true
  engine.last_shot_replay_path = "/dev/null"
  engine:setupLevel(workload.level)

  local t1 = now()

  local initial_balls = nil
  local registered_balls = workload.balls or 1
  if registered_balls > 1 then
    initial_balls = {}
    for i = 1, registered_balls do
      local x = (i / (registered_balls + 1)) * LevelManager.virtual_width
      initial_balls[#initial_balls + 1] = Ball.new(x, 50)
    end
  end
  engine:resetTurn(initial_balls)

  local t2 = now()

  if trace_path then
    GameplayTraceExporter.init(trace_path, { include_snapshot = opts.trace_snapshot == true })
    if not GameplayTraceExporter.file then
      error("cannot open trace file: " .. trace_path)
    end
    engine.trace_exporter = GameplayTraceExporter
  end

  engine.current_aim_angle = angle
  engine:launchBalls()

  local steps = 0
  while not shot_done and steps < max_steps do
    engine:update(FIXED_DT)
    steps = steps + 1
  end

  if trace_path then
    GameplayTraceExporter.close()
    engine.trace_exporter = nil
  end

  local t3 = now()

  local styles = {}
  local style_total = 0
  for name, count in pairs(style_counts) do
    styles[#styles + 1] = name .. ":" .. count
    style_total = style_total + count
  end
  table.sort(styles)

  local features = {
    steps = steps,
    completed = shot_done,
    reason = engine.last_removal_reason or (shot_done and "all_balls_removed" or "step_limit"),
    score = engine:getTurnScore(),
    peg_score = engine:getTurnPegScore(),
    bonus = engine.bonusScore,
    style_points = engine.styleScore,
    style_total = style_total,
    styles = table.concat(styles, ","),
    pegs_hit = #engine.turnPegsHit,
    reds_hit = engine.redPegsHitAmount,
    multiplier = engine.currentMultiplier,
    is_fever = engine.isFever,
    balls = registered_balls,
    spawned = (engine.next_ball_id - 1) - registered_balls,
    mem_kb = collectgarbage("count"),
  }

  local t4 = now()

  return {
    index = index,
    angle = angle,
    features = features,
    styles_map = style_counts,
    t_init = math.floor((t1 - t0) * 1e6 + 0.5),
    t_reset = math.floor((t2 - t1) * 1e6 + 0.5),
    t_sim = math.floor((t3 - t2) * 1e6 + 0.5),
    t_extract = math.floor((t4 - t3) * 1e6 + 0.5),
  }
end

local function serialize_row(workload, repeat_index, result)
  local f = result.features
  local fields = {
    '"w":' .. json_string(workload.id),
    '"r":' .. tostring(repeat_index),
    '"i":' .. tostring(result.index),
    '"angle":' .. json_number(result.angle),
    '"steps":' .. tostring(f.steps),
    '"completed":' .. tostring(f.completed),
    '"reason":' .. json_string(f.reason),
    '"score":' .. json_number(f.score),
    '"peg_score":' .. json_number(f.peg_score),
    '"bonus":' .. json_number(f.bonus),
    '"style_points":' .. json_number(f.style_points),
    '"style_total":' .. tostring(f.style_total),
    '"styles":' .. json_string(f.styles),
    '"pegs_hit":' .. tostring(f.pegs_hit),
    '"reds_hit":' .. tostring(f.reds_hit),
    '"multiplier":' .. tostring(f.multiplier),
    '"is_fever":' .. tostring(f.is_fever),
    '"balls":' .. tostring(f.balls),
    '"mem_kb":' .. json_number(f.mem_kb),
    '"t_init":' .. tostring(result.t_init),
    '"t_reset":' .. tostring(result.t_reset),
    '"t_sim":' .. tostring(result.t_sim),
    '"t_extract":' .. tostring(result.t_extract),
  }
  return "{" .. table.concat(fields, ",") .. "}"
end

-- ===========================================================================
-- Determinism spot check
-- ===========================================================================
local function feature_signature(result)
  local f = result.features
  return table.concat({
    tostring(result.index),
    tostring(f.steps),
    tostring(f.completed),
    tostring(f.reason),
    tostring(f.score),
    tostring(f.peg_score),
    tostring(f.pegs_hit),
    tostring(f.reds_hit),
    tostring(f.multiplier),
    tostring(f.styles),
  }, "|")
end

local function determinism_check(workload, count)
  if count <= 0 then return { checked = 0, deterministic = true, mismatches = {} } end
  local indices = {}
  for k = 1, count do
    local i = math.floor((k - 1) * AIM_STEPS / math.max(1, count - 1) + 0.5)
    if i > AIM_STEPS then i = AIM_STEPS end
    indices[#indices + 1] = i
  end
  local mismatches = {}
  for _, i in ipairs(indices) do
    local a = run_candidate(workload, i)
    local b = run_candidate(workload, i)
    local sa, sb = feature_signature(a), feature_signature(b)
    if sa ~= sb then
      mismatches[#mismatches + 1] = { index = i, first = sa, second = sb }
    end
  end
  return {
    checked = #indices,
    deterministic = #mismatches == 0,
    mismatches = mismatches,
  }
end

-- ===========================================================================
-- Workload sweep
-- ===========================================================================
local function warmup(workload, count)
  if count <= 0 then return 0 end
  local t0 = now()
  for k = 1, count do
    local i = math.floor((k - 1) * AIM_STEPS / math.max(1, count - 1) + 0.5)
    if i > AIM_STEPS then i = AIM_STEPS end
    run_candidate(workload, i)
  end
  return now() - t0
end

local function sweep(workload, repeat_index, indices, raw_file, progress)
  local n = #indices
  local phase_init, phase_reset, phase_sim, phase_extract, phase_output = {}, {}, {}, {}, {}
  local steps_all, scores, pegs_all, reds_all, mem_all = {}, {}, {}, {}, {}
  local reasons, styles = {}, {}
  local completed, incomplete = 0, 0
  local index_count = 0

  local t_sweep0 = now()
  for pos = 1, n do
    local index = indices[pos]
    local result = run_candidate(workload, index)
    local f = result.features

    phase_init[#phase_init + 1] = result.t_init
    phase_reset[#phase_reset + 1] = result.t_reset
    phase_sim[#phase_sim + 1] = result.t_sim
    phase_extract[#phase_extract + 1] = result.t_extract
    steps_all[#steps_all + 1] = f.steps
    scores[#scores + 1] = f.score
    pegs_all[#pegs_all + 1] = f.pegs_hit
    reds_all[#reds_all + 1] = f.reds_hit
    mem_all[#mem_all + 1] = f.mem_kb
    reasons[f.reason] = (reasons[f.reason] or 0) + 1
    for name in f.styles:gmatch("[^,]+") do
      styles[name] = (styles[name] or 0) + 1
    end
    if f.completed then completed = completed + 1 else incomplete = incomplete + 1 end

    index_count = index_count + 1

    local t_out0 = now()
    if raw_file then
      raw_file:write(serialize_row(workload, repeat_index, result), "\n")
    end
    phase_output[#phase_output + 1] = math.floor((now() - t_out0) * 1e6 + 0.5)

    if progress and (pos % progress == 0 or pos == n) then
      local elapsed = now() - t_sweep0
      print(string.format("  [%s r%d] %d/%d candidates (%.1fs, %.1f cand/s)",
        workload.id, repeat_index, pos, n, elapsed, pos / math.max(elapsed, 1e-9)))
      io.stdout:flush()
    end
  end
  local total = now() - t_sweep0

  local function agg(values)
    return stats_of(values)
  end
  local all_phases = {}
  for i = 1, #phase_init do
    all_phases[i] = phase_init[i] + phase_reset[i] + phase_sim[i] + phase_extract[i] + phase_output[i]
  end

  return {
    workload = workload.id,
    level = workload.level,
    group = workload.group,
    balls = workload.balls,
    repeat_index = repeat_index,
    candidates = index_count,
    completed = completed,
    incomplete = incomplete,
    wall_seconds = total,
    candidates_per_second = index_count / math.max(total, 1e-9),
    sim_steps_per_second = agg(steps_all).sum / math.max(agg(phase_sim).sum / 1e6, 1e-9),
    phases = {
      init = agg(phase_init),
      reset = agg(phase_reset),
      sim = agg(phase_sim),
      extract = agg(phase_extract),
      output = agg(phase_output),
      total = agg(all_phases),
    },
    steps = agg(steps_all),
    score = agg(scores),
    pegs_hit = agg(pegs_all),
    reds_hit = agg(reds_all),
    mem_kb = agg(mem_all),
    reasons = reasons,
    style_hits = styles,
  }
end

-- ===========================================================================
-- Candidate search: fixture authoring aid over the legal aim grid
-- ===========================================================================
local function matches_filter(features, filter)
  if filter == nil or filter == true then return true end
  local kind, value = tostring(filter):match("^([%a_]+):(.*)$")
  if kind == "style" then
    return features.styles:find(value, 1, true) ~= nil
  elseif kind == "pegs" then
    return features.pegs_hit >= (tonumber(value) or 1)
  elseif kind == "reds" then
    return features.reds_hit >= (tonumber(value) or 1)
  elseif kind == "spawn" then
    return features.spawned >= (tonumber(value) or 1)
  elseif kind == "score" then
    return features.score >= (tonumber(value) or 1)
  end
  if filter == "fever" then return features.is_fever end
  if filter == "bucket" then return features.reason == "bucket_caught" end
  if filter == "completed" then return features.completed end
  if filter == "spawned" then return features.spawned > 0 end
  error("unknown --match filter: " .. tostring(filter))
end

local function run_search()
  local level = args["level"]
  if type(level) ~= "string" then
    print("ERROR: --search requires --level NAME")
    love.event.quit(1)
    return
  end
  local balls = arg_number("balls", 1)
  local max_steps = arg_number("max-steps", MAX_STEPS)
  local limit = arg_number("limit", 0)
  local filter = args["match"]
  local workload = { id = "search_" .. level, level = level, balls = balls }
  local indices = build_index_list()
  print(string.format("search: level=%s balls=%d indices=%d filter=%s",
    level, balls, #indices, tostring(filter)))
  local matches = 0
  for _, index in ipairs(indices) do
    local result = run_candidate(workload, index, { max_steps = max_steps })
    local f = result.features
    if matches_filter(f, filter) then
      matches = matches + 1
      if limit == 0 or matches <= limit then
        print(JSON.stringify({
          index = index,
          angle = result.angle,
          steps = f.steps,
          completed = f.completed,
          reason = f.reason,
          score = f.score,
          peg_score = f.peg_score,
          bonus = f.bonus,
          style_points = f.style_points,
          styles = f.styles,
          is_fever = f.is_fever,
          pegs_hit = f.pegs_hit,
          reds_hit = f.reds_hit,
          spawned = f.spawned,
        }))
        io.stdout:flush()
      end
    end
  end
  print(string.format("search: %d match(es)", matches))
end

-- ===========================================================================
-- Reference fixture capture
-- ===========================================================================
local FIXTURE_CATEGORIES = {
  shape_boundary = true, near_tie = true, graze = true,
  overlap_correction = true, clearing = true, fever = true, power = true,
  style = true, line_metadata = true, bucket = true, multiball = true,
  completion = true,
}

local function shell_quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

local function read_file_bytes(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return data
end

-- Hash a file. Prefers LÖVE's built-in digest (io.popen is unavailable under
-- LÖVE); the popen path keeps the helper usable from plain LuaJIT.
local function sha256_file(path)
  if love and love.data and love.data.hash and love.data.encode then
    local data, err = read_file_bytes(path)
    if not data then return nil, err end
    return love.data.encode("string", "hex", love.data.hash("sha256", data))
  end
  local pipe = io.popen("sha256sum " .. shell_quote(path) .. " 2>/dev/null")
  if not pipe then return nil, "no hash backend" end
  local line = pipe:read("*l")
  pipe:close()
  return line and line:match("^(%x+)$") or nil
end

local function count_lines(path)
  local f = io.open(path, "r")
  if not f then return 0 end
  local count = 0
  for _ in f:lines() do count = count + 1 end
  f:close()
  return count
end

local function load_table_file(path, what)
  local chunk, err = loadfile(path)
  if not chunk then
    error("cannot load " .. what .. " at " .. path .. ": " .. tostring(err))
  end
  local ok, value = pcall(chunk)
  if not ok then
    error("error running " .. what .. " at " .. path .. ": " .. tostring(value))
  end
  return value
end

local function read_level_artifact(level)
  local path = repo_root .. "/interchange/levels/" .. level .. ".v1.json"
  local ok, data = pcall(CanonicalJSON.decode_file, path)
  if not ok then
    error("missing level artifact " .. path
      .. " (run scripts/export_interchange.sh first): " .. tostring(data))
  end
  return data, path
end

local function validate_fixture_catalog(catalog)
  if type(catalog) ~= "table" or catalog.version ~= 1 then
    error("fixture catalog must be a table with version = 1")
  end
  if type(catalog.fixtures) ~= "table" then
    error("fixture catalog must contain a fixtures array")
  end
  local seen = {}
  for i, fx in ipairs(catalog.fixtures) do
    local where = "fixtures[" .. i .. "]"
    if type(fx.id) ~= "string" or fx.id == "" then
      error(where .. ".id must be a non-empty string")
    end
    if seen[fx.id] then error("duplicate fixture id " .. fx.id) end
    seen[fx.id] = true
    if not FIXTURE_CATEGORIES[fx.category] then
      error(where .. " has unknown category " .. tostring(fx.category))
    end
    if fx.kind ~= "shot" and fx.kind ~= "scenario" then
      error(where .. ".kind must be shot or scenario")
    end
    if fx.trace ~= nil and type(fx.trace) ~= "boolean" then
      error(where .. ".trace must be a boolean")
    end
    if fx.kind == "shot" then
      if type(fx.level) ~= "string" then
        error(where .. ".level is required for shot fixtures")
      end
      if type(fx.aim_index) ~= "number" or fx.aim_index ~= math.floor(fx.aim_index)
        or fx.aim_index < 0 or fx.aim_index > AIM_STEPS then
        error(where .. ".aim_index must be an integer in 0.." .. AIM_STEPS)
      end
      if fx.delay ~= nil and fx.delay ~= 0 then
        error(where .. ".delay must be 0 in fixture schema v1 (timing search is M8)")
      end
      if fx.balls ~= nil and (type(fx.balls) ~= "number" or fx.balls < 1) then
        error(where .. ".balls must be >= 1")
      end
      fx.balls = fx.balls or 1
      fx.completion = fx.completion or "bench"
      if fx.completion ~= "bench" and fx.completion ~= "clearing" then
        error(where .. ".completion must be bench or clearing")
      end
    else
      if fx.trace then
        error(where .. " scenario fixtures cannot capture gameplay traces")
      end
      if fx.level ~= nil or fx.aim_index ~= nil or fx.balls ~= nil then
        error(where .. " scenario fixtures must not declare level/aim_index/balls")
      end
    end
  end
end

local function fixture_provenance(level)
  local revision = args["reference-revision"]
  local tree = args["reference-tree"]
  local config_sha = args["config-sha256"]
  if type(revision) ~= "string" or type(tree) ~= "string" or type(config_sha) ~= "string" then
    error("fixture capture requires --reference-revision, --reference-tree, --config-sha256")
  end
  local source = {
    reference_revision = revision,
    reference_tree = tree,
    config_sha256 = config_sha,
  }
  if level then
    local artifact, artifact_path = read_level_artifact(level)
    source.level = level
    local hash, hash_err = sha256_file(artifact_path)
    if not hash then
      error("cannot hash level artifact for fixture capture: " .. tostring(hash_err))
    end
    source.level_sha256 = hash
    return source, artifact
  end
  return source, nil
end

local function capture_shot_fixture(fx, opts)
  opts = opts or {}
  local source, artifact = fixture_provenance(fx.level)
  local trace_rel, trace_path
  if fx.trace then
    trace_rel = "fixtures/traces/" .. fx.id .. ".jsonl"
    if opts.check then
      trace_path = os.tmpname()
    else
      trace_path = opts.traces_dir .. "/" .. fx.id .. ".jsonl"
    end
  end
  local workload = { id = fx.id, level = fx.level, balls = fx.balls }
  local result = run_candidate(workload, fx.aim_index, {
    max_steps = fx.max_steps or MAX_STEPS,
    clearing = fx.completion == "clearing",
    trace_path = trace_path,
    trace_snapshot = opts.trace_snapshot == true,
  })
  local f = result.features
  local record = {
    format = "peggle.fixture",
    schema_version = 1,
    id = fx.id,
    category = fx.category,
    kind = "shot",
    source = source,
    seed = {
      level_seed = artifact.level_seed,
      type_counts = artifact.type_counts,
    },
    action = {
      kind = "shot",
      aim_index = fx.aim_index,
      angle = result.angle,
      delay = 0,
      balls = fx.balls,
    },
    completion = {
      rule = fx.completion,
      completed = f.completed,
      reason = f.reason,
      steps = f.steps,
      max_steps = fx.max_steps or MAX_STEPS,
    },
    result = {
      score = f.score,
      peg_score = f.peg_score,
      bonus = f.bonus,
      style_points = f.style_points,
      styles = CanonicalJSON.object(result.styles_map),
      pegs_hit = f.pegs_hit,
      reds_hit = f.reds_hit,
      multiplier = f.multiplier,
      is_fever = f.is_fever,
      balls = f.balls,
      balls_spawned = f.spawned,
    },
  }
  if trace_path then
    local trace_hash, hash_err = sha256_file(trace_path)
    if not trace_hash then
      error("cannot hash fixture trace: " .. tostring(hash_err))
    end
    record.trace = {
      path = trace_rel,
      sha256 = trace_hash,
      events = count_lines(trace_path) - 1,
    }
  end
  return record, trace_path
end

local function snapshot_config()
  local snap = {}
  for k, v in pairs(Config) do
    if type(v) ~= "table" then snap[k] = v end
  end
  return snap
end

local function restore_config(snap)
  for k in pairs(Config) do
    if type(Config[k]) ~= "table" then Config[k] = nil end
  end
  for k, v in pairs(snap) do Config[k] = v end
end

local function capture_scenario_fixture(fx, scenario)
  local source = fixture_provenance(nil)
  local saved_config = snapshot_config()
  local saved_width, saved_height = LevelManager.virtual_width, LevelManager.virtual_height
  local ok, outcome = pcall(scenario.run)
  restore_config(saved_config)
  LevelManager.virtual_width, LevelManager.virtual_height = saved_width, saved_height
  if not ok then
    error("scenario " .. fx.id .. " failed: " .. tostring(outcome))
  end
  return {
    format = "peggle.fixture",
    schema_version = 1,
    id = fx.id,
    category = fx.category,
    kind = "scenario",
    source = source,
    seed = {
      level_seed = scenario.seed or 1,
      type_counts = scenario.type_counts or { red = 0, green = 0 },
    },
    action = { kind = "scenario", name = fx.id },
    completion = {
      rule = "scenario",
      completed = outcome.completed ~= false,
      reason = outcome.reason or "probe_complete",
      steps = outcome.steps or 0,
      max_steps = outcome.max_steps or outcome.steps or 0,
    },
    result = CanonicalJSON.object(outcome.result or {}),
  }
end

local function fixture_record_text(record)
  return CanonicalJSON.encode(record) .. "\n"
end

local function read_expected_fixture(out_dir, id)
  local path = out_dir .. "/" .. id .. ".json"
  local data, err = read_file_bytes(path)
  if not data then
    error("missing expected fixture " .. path
      .. " (capture it with scripts/capture_fixtures.sh): " .. tostring(err))
  end
  local ok, decoded = pcall(CanonicalJSON.decode, data)
  if not ok then
    error("cannot decode expected fixture " .. path .. ": " .. tostring(decoded))
  end
  return decoded, data, path
end

local function verify_fixture_record(record, expected_text, expected_path)
  local text = fixture_record_text(record)
  if text ~= expected_text then
    error("fixture " .. record.id .. ": regenerated record differs from "
      .. expected_path)
  end
  return expected_path
end

local function verify_reference_trace(traces_dir, id, expected_record)
  local expected_trace = expected_record.trace
  if type(expected_trace) ~= "table" then
    error("fixture " .. id .. ": expected record has no trace metadata")
  end
  local path = traces_dir .. "/" .. id .. ".jsonl"
  local hash, hash_err = sha256_file(path)
  if not hash then
    error("fixture " .. id .. ": missing reference trace " .. path
      .. " (" .. tostring(hash_err) .. ")")
  end
  if hash ~= expected_trace.sha256 then
    error(string.format(
      "fixture %s: reference trace hash mismatch in %s (expected %s, got %s)",
      id, path, tostring(expected_trace.sha256), hash))
  end
  local lines = count_lines(path)
  if lines ~= expected_trace.events + 1 then
    error(string.format(
      "fixture %s: reference trace event count mismatch in %s"
        .. " (expected %d events + 1 header line, got %d lines)",
      id, path, expected_trace.events, lines))
  end
  return path
end

local function verify_regenerated_trace(id, generated_path, reference_path, record)
  local generated, gerr = read_file_bytes(generated_path)
  if not generated then
    error("fixture " .. id .. ": cannot read regenerated trace "
      .. tostring(generated_path) .. ": " .. tostring(gerr))
  end
  local reference, rerr = read_file_bytes(reference_path)
  if not reference then
    error("fixture " .. id .. ": cannot read reference trace "
      .. reference_path .. ": " .. tostring(rerr))
  end
  if generated ~= reference then
    local reference_hash = sha256_file(reference_path)
    if record.trace.sha256 ~= reference_hash then
      error(string.format(
        "fixture %s: trace hash mismatch (regenerated %s vs reference %s)",
        id, tostring(record.trace.sha256), tostring(reference_hash)))
    end
    error("fixture " .. id .. ": trace byte mismatch despite equal SHA-256")
  end
end

local function write_fixture_record(out_dir, record)
  local path = out_dir .. "/" .. record.id .. ".json"
  local text = fixture_record_text(record)
  local f, err = io.open(path, "w")
  if not f then error("cannot write " .. path .. ": " .. tostring(err)) end
  f:write(text)
  f:close()
  return path
end

local function load_scenarios()
  local path = repo_root .. "/fixtures/scenarios.lua"
  local scenarios = load_table_file(path, "scenario module")
  if type(scenarios) ~= "table" then
    error("scenario module must return a table")
  end
  local by_id = {}
  for _, scenario in ipairs(scenarios) do
    if type(scenario.id) ~= "string" or type(scenario.run) ~= "function" then
      error("scenario entries need an id and a run function")
    end
    if by_id[scenario.id] then
      error("duplicate scenario id " .. scenario.id)
    end
    by_id[scenario.id] = scenario
  end
  return by_id
end

local function selected_fixtures(catalog)
  local wanted = args["id"]
  local out = {}
  for _, fx in ipairs(catalog.fixtures) do
    if wanted == nil or wanted == true or fx.id == wanted then
      out[#out + 1] = fx
    end
  end
  if #out == 0 then error("no fixtures selected") end
  return out
end

local function list_fixtures(catalog)
  for _, fx in ipairs(catalog.fixtures) do
    print(string.format("%-34s %-18s %s", fx.id, fx.category, fx.kind))
  end
end

local function run_fixtures()
  local catalog_path = (args["catalog"] ~= true and args["catalog"]) or (repo_root .. "/fixtures/catalog.lua")
  local out_dir = (args["fixtures-out"] ~= true and args["fixtures-out"]) or (repo_root .. "/fixtures/expected")
  local traces_dir = (args["fixtures-traces"] ~= true and args["fixtures-traces"])
    or (repo_root .. "/fixtures/traces")
  local catalog = load_table_file(catalog_path, "fixture catalog")
  validate_fixture_catalog(catalog)

  if args["list-fixtures"] then
    list_fixtures(catalog)
    return
  end

  local scenarios = load_scenarios()
  local check = args["check"] == true
  local snapshots = args["fixtures-snapshots"] == true
  local fixtures = selected_fixtures(catalog)
  local written = 0
  for _, fx in ipairs(fixtures) do
    if fx.kind == "shot" then
      if check then
        local expected_record, expected_text = read_expected_fixture(out_dir, fx.id)
        local record, tmp_trace = capture_shot_fixture(fx, { check = true })
        local ok, err = pcall(function()
          if fx.trace then
            local reference_trace = verify_reference_trace(traces_dir, fx.id, expected_record)
            verify_regenerated_trace(fx.id, tmp_trace, reference_trace, record)
          end
          verify_fixture_record(record, expected_text,
            out_dir .. "/" .. fx.id .. ".json")
        end)
        if tmp_trace then os.remove(tmp_trace) end
        if not ok then error(err, 0) end
        print(string.format("verified %-34s %s/%s.json", fx.id, out_dir, fx.id))
      else
        local record = capture_shot_fixture(fx, { traces_dir = traces_dir, trace_snapshot = snapshots })
        local path = write_fixture_record(out_dir, record)
        print(string.format("captured %-34s %s", fx.id, path))
      end
    else
      local scenario = scenarios[fx.id]
      if scenario == nil then
        error("no scenario implementation for fixture " .. fx.id)
      end
      if check then
        local _, expected_text, expected_path = read_expected_fixture(out_dir, fx.id)
        local record = capture_scenario_fixture(fx, scenario)
        verify_fixture_record(record, expected_text, expected_path)
        print(string.format("verified %-34s %s", fx.id, expected_path))
      else
        local record = capture_scenario_fixture(fx, scenario)
        local path = write_fixture_record(out_dir, record)
        print(string.format("captured %-34s %s", fx.id, path))
      end
    end
    written = written + 1
  end
  print(string.format("fixtures: %d record(s) %s", written, check and "verified" or "written"))
end

-- ===========================================================================
-- Report / output
-- ===========================================================================
local function print_workloads()
  print("Workloads:")
  for _, w in ipairs(ALL_WORKLOADS) do
    print(string.format("  %-26s group=%-11s level=%-18s balls=%d  %s",
      w.id, w.group, w.level, w.balls, w.note or ""))
  end
end

local function write_summary(prefix, summary)
  local path = prefix .. ".summary.json"
  local f, err = io.open(path, "w")
  if not f then
    print("ERROR: cannot open summary file: " .. tostring(err))
    love.event.quit(1)
    return
  end
  f:write(JSON.stringify(summary))
  f:write("\n")
  f:close()
  print("wrote " .. path)
  return path
end

-- ===========================================================================
-- Entry point
-- ===========================================================================
function love.load()
  local t_start = now()
  local age_start = process_age_ms()
  local rss_start = rss_kb()

  print(string.format("harness v%d | love %s | lua %s", HARNESS_VERSION,
    table.concat({ love.getVersion() }, "."),
    (function()
      local ok, jit = pcall(require, "jit")
      return ok and jit and jit.version or _VERSION
    end)()))
  print("reference: " .. ref_root)
  print(string.format("grid: %d indices (%d..%d), snapping mismatches=%d",
    GRID.count, 0, AIM_STEPS, GRID.mismatches))

  if args["list"] then
    print_workloads()
    love.event.quit()
    return
  end

  if GRID.mismatches > 0 then
    print("ERROR: aim grid does not match the reference snapping function")
    local m = GRID.first_mismatch
    print(string.format("  first mismatch: i=%d angle=%.17g snapped=%.17g",
      m.index, m.angle, m.snapped))
    love.event.quit(1)
    return
  end

  if args["search"] then
    local ok, err = pcall(run_search)
    if not ok then
      print("ERROR: " .. tostring(err))
      io.stdout:flush()
      love.event.quit(1)
      return
    end
    love.event.quit()
    return
  end

  if args["fixtures"] or args["list-fixtures"] then
    local ok, err = pcall(run_fixtures)
    if not ok then
      print("ERROR: " .. tostring(err))
      io.stdout:flush()
      love.event.quit(1)
      return
    end
    love.event.quit()
    return
  end

  if args["m2-capture"] or args["m2-rng"] or args["m2-peg-colors"] or args["m2-checkpoints"] then
    local ok, err = pcall(function()
      local capture_m2 = require("capture_m2_fixtures")
      local levels = {}
      if type(args["levels"]) == "string" then
        for tok in args["levels"]:gmatch("[^,]+") do
          tok = tok:match("^%s*(.-)%s*$")
          if tok ~= "" then levels[#levels + 1] = tok end
        end
      end
      capture_m2.run({
        repo_root = repo_root,
        args = args,
        levels = levels,
        rng_out = (args["rng-out"] ~= true and args["rng-out"]) or (repo_root .. "/fixtures/rng"),
        checkpoints_out = (args["checkpoints-out"] ~= true and args["checkpoints-out"])
          or (repo_root .. "/fixtures/checkpoints"),
        read_file_bytes = read_file_bytes,
        sha256_file = sha256_file,
      })
    end)
    if not ok then
      print("ERROR: " .. tostring(err))
      io.stdout:flush()
      love.event.quit(1)
      return
    end
    love.event.quit()
    return
  end

  local workloads = selected_workloads()
  if #workloads == 0 then
    print("ERROR: no workloads selected")
    love.event.quit(1)
    return
  end

  local indices = build_index_list()
  local warmup_count = arg_number("warmup", 8)
  local repeat_count = arg_number("repeat", 1)
  local check_count = arg_number("check-candidates", 3)

  if args["self-check"] then
    print("self-check: grid identity OK")
    for _, w in ipairs(workloads) do
      local check = determinism_check(w, check_count)
      print(string.format("  %-26s determinism checked=%d mismatches=%d",
        w.id, check.checked, #check.mismatches))
    end
    love.event.quit()
    return
  end

  local raw_path = nil
  local raw_file = nil
  if OUT_PREFIX then
    if WRITE_RAW then
      raw_path = OUT_PREFIX .. ".candidates.jsonl"
      local err
      raw_file, err = io.open(raw_path, "w")
      if not raw_file then
        print("ERROR: cannot open raw file: " .. tostring(err))
        love.event.quit(1)
        return
      end
    end
  end

  local summary = {
    harness_version = HARNESS_VERSION,
    date_utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    run_id = (args["run-id"] ~= true and args["run-id"]) or nil,
    host_label = (args["host-label"] ~= true and args["host-label"]) or nil,
    reference = {
      revision = (args["reference-revision"] ~= true and args["reference-revision"]) or nil,
      tree = (args["reference-tree"] ~= true and args["reference-tree"]) or nil,
      config_sha256 = (args["config-sha256"] ~= true and args["config-sha256"]) or nil,
      root = ref_root,
    },
    grid = GRID,
    options = {
      stride = (args["stride"] ~= true and tonumber(args["stride"])) or 1,
      index_count = #indices,
      max_steps = MAX_STEPS,
      clearing = CLEARING,
      replay_serialize = not args["no-replay-serialize"],
      warmup = warmup_count,
      repeat_count = repeat_count,
      check_candidates = check_count,
    },
    host = host_info(),
    cold_start = {
      process_age_at_load_ms = age_start,
      setup_seconds = now() - t_start,
    },
    memory = {
      rss_kb_start = rss_start,
      lua_kb_start = collectgarbage("count"),
    },
    workloads = {},
    totals = {
      candidates = 0,
      completed = 0,
      incomplete = 0,
      wall_seconds = 0,
    },
  }

  local sweep_start_age = process_age_ms()

  for _, w in ipairs(workloads) do
    collectgarbage("collect")
    local rss_before = rss_kb()
    local mem_before = collectgarbage("count")

    local check = determinism_check(w, check_count)
    local warmup_seconds = warmup(w, warmup_count)

    for r = 1, repeat_count do
      local result = sweep(w, r, indices, raw_file, PROGRESS_EVERY)
      result.determinism = check
      result.warmup_seconds = warmup_seconds
      result.rss_kb_before = rss_before
      result.rss_kb_after = rss_kb()
      result.lua_kb_before = mem_before
      result.lua_kb_after = collectgarbage("count")
      summary.workloads[#summary.workloads + 1] = result
      summary.totals.candidates = summary.totals.candidates + result.candidates
      summary.totals.completed = summary.totals.completed + result.completed
      summary.totals.incomplete = summary.totals.incomplete + result.incomplete
      summary.totals.wall_seconds = summary.totals.wall_seconds + result.wall_seconds
    end
  end

  summary.cold_start.process_age_at_sweep_ms = sweep_start_age
  summary.memory.rss_kb_end = rss_kb()
  summary.memory.lua_kb_end = collectgarbage("count")
  summary.harness_wall_seconds = now() - t_start

  if raw_file then
    raw_file:close()
    print("wrote " .. raw_path)
  end
  if SUMMARY_PREFIX then
    write_summary(SUMMARY_PREFIX, summary)
  end

  print(string.format("done: %d candidates, %.1fs (%.1f candidates/s), incomplete=%d",
    summary.totals.candidates, summary.totals.wall_seconds,
    summary.totals.candidates / math.max(summary.totals.wall_seconds, 1e-9),
    summary.totals.incomplete))

  love.event.quit()
end
