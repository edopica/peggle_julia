-- M2 reference captures: RNG sequences, peg-color initialization, and
-- ready-to-aim checkpoints.
--
-- This module runs under LÖVE because it needs the real
-- love.math.RandomGenerator and the vendored reference engine. It is invoked
-- by harness/main.lua when one of --m2-capture/--m2-rng/--m2-peg-colors/
-- --m2-checkpoints is present and is never part of the sweep/fixture paths.
--
-- Every record is canonical JSON (tools/canonical_json.lua) with one trailing
-- newline. With --check the records are re-captured in memory and compared
-- against the committed files; the module never writes in check mode. The
-- reference is only monkeypatched at runtime (newRandomGenerator), never
-- edited.
--
-- Fixture shapes:
--   fixtures/rng/rng_sequences.v1.json  (format "peggle.rng_fixtures")
--   fixtures/rng/peg_colors.v1.json     (format "peggle.peg_colors_fixtures")
--   fixtures/checkpoints/<name>.v1.json (format "peggle.checkpoint", schema v1)

local Config = require("src.config")
local Engine = require("src.engine.core")
local Ball = require("src.entities.ball")
local PegColors = require("src.systems.peg_colors")
local LevelManager = require("src.systems.level_manager")
local CanonicalJSON = require("canonical_json")

local M = {}

local FIXED_SEEDS = {
  0, 1, 42, 123, 345, 4294967295, 4294967296, 9007199254740991, 3735928559,
}

local RNG_SEQUENCE_OPS = {
  { kind = "random", lo = 1, hi = 100, count = 8 },
  { kind = "random", lo = 1, hi = 10, count = 8 },
  { kind = "random", lo = 1, hi = 1, count = 4 },
  { kind = "random", lo = 2, hi = 1000000, count = 8 },
  { kind = "random", lo = 1, hi = 1801, count = 8 },
  { kind = "random01", count = 8 },
}

local ARRAY_KEYS = { "blue", "green", "purple", "red" }

-- ===========================================================================
-- Helpers
-- ===========================================================================

local function array(t)
  return CanonicalJSON.array(t or {})
end

local function object(t)
  return CanonicalJSON.object(t or {})
end

local FFI_OK, FFI = pcall(require, "ffi")
local BITS_UNION = FFI_OK and FFI.new("union { double d; uint64_t u; }") or nil

-- IEEE-754 bit pattern of a double as "0x%016x" (LuaJIT FFI; the brief's
-- random01 encoding). The pack fallback is only for a stripped FFI build.
local function float_bits_hex(x)
  if BITS_UNION then
    BITS_UNION.d = x
    return string.format("0x%016x", BITS_UNION.u)
  end
  local packed = love.data.pack("string", "d", x)
  local bytes = {}
  for i = #packed, 1, -1 do
    bytes[#bytes + 1] = string.format("%02x", packed:byte(i))
  end
  return "0x" .. table.concat(bytes)
end

-- Generic canonical wrapping for tracker maps: non-empty contiguous numeric
-- keys become arrays, everything else (including every empty table) becomes
-- an object, matching the canonical codec's explicit-container rules.
local function is_array_like(v)
  local n = 0
  for k in pairs(v) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      return false, 0
    end
    n = n + 1
  end
  for i = 1, n do
    if v[i] == nil then return false, 0 end
  end
  return true, n
end

local function wrap(v)
  if type(v) ~= "table" then return v end
  local ok, n = is_array_like(v)
  if ok and n > 0 then
    local out = array({})
    for i = 1, n do out[i] = wrap(v[i]) end
    return out
  end
  local out = {}
  for k, value in pairs(v) do out[tostring(k)] = wrap(value) end
  return object(out)
end

-- PegColors keeps its purple queue in a module-local; it is reachable through
-- the closure upvalue, which is the only way to snapshot the raw queue order
-- (including already-hit entries the accessor does not expose).
local function purple_queue_refs()
  local fn = PegColors.assign_next_purple_pegs
  for i = 1, 16 do
    local name, value = debug.getupvalue(fn, i)
    if name == nil then break end
    if name == "purple_queue" then return value end
  end
  error("capture_m2_fixtures: cannot read the PegColors purple_queue upvalue")
end

local function peg_ids(pegs)
  local out = array({})
  for _, p in ipairs(pegs) do out[#out + 1] = p.original_index end
  return out
end

local function ids_of(pegs)
  local out = array({})
  for _, p in ipairs(pegs) do out[#out + 1] = p.original_index end
  return out
end

local function op_record(op)
  if op.kind == "random" then
    return { kind = "random", lo = op.lo, hi = op.hi, count = op.count }
  end
  return { kind = op.kind, count = op.count }
end

local function draw_into(gen, op, results)
  for _ = 1, op.count do
    if op.kind == "random" then
      results[#results + 1] = gen:random(op.lo, op.hi)
    else
      results[#results + 1] = float_bits_hex(gen:random())
    end
  end
end

local function record_text(record)
  return CanonicalJSON.encode(record) .. "\n"
end

local function write_file(path, text)
  local f, err = io.open(path, "w")
  if not f then error("cannot write " .. path .. ": " .. tostring(err)) end
  f:write(text)
  f:close()
end

local function emit(opts, path, record, has_filter, filter_fn)
  if not opts.args["check"] then
    write_file(path, record_text(record))
    print("captured " .. path)
    return
  end
  local existing = opts.read_file_bytes(path)
  if not existing then
    error("missing M2 fixture " .. path .. " (run scripts/capture_m2.sh first)")
  end
  if has_filter then
    local committed = CanonicalJSON.decode(existing)
    if record_text(filter_fn(record)) ~= record_text(filter_fn(committed)) then
      error("M2 fixture subset differs from re-capture: " .. path)
    end
    print("verified " .. path .. " (filtered)")
  else
    if existing ~= record_text(record) then
      error("M2 fixture differs from re-capture: " .. path)
    end
    print("verified " .. path)
  end
end

-- ===========================================================================
-- Source provenance and levels
-- ===========================================================================

local function source_provenance(args)
  local revision = args["reference-revision"]
  local tree = args["reference-tree"]
  local config_sha = args["config-sha256"]
  if type(revision) ~= "string" or type(tree) ~= "string" or type(config_sha) ~= "string" then
    error("M2 capture requires --reference-revision, --reference-tree, --config-sha256")
  end
  return {
    reference_revision = revision,
    reference_tree = tree,
    config_sha256 = config_sha,
  }
end

local function discover_levels(repo_root, read_file_bytes)
  local names = {}
  local manifest = read_file_bytes(repo_root .. "/interchange/files.sha256")
  if manifest then
    for line in manifest:gmatch("[^\n]+") do
      local name = line:match("/levels/([%w_%.%-]+)%.v1%.json$")
      if name then names[#names + 1] = name end
    end
  end
  table.sort(names)
  return names
end

local function load_artifacts(repo_root, levels, read_file_bytes, sha256_file)
  local artifacts = {}
  for _, name in ipairs(levels) do
    local path = repo_root .. "/interchange/levels/" .. name .. ".v1.json"
    local bytes = read_file_bytes(path)
    if not bytes then
      error("missing level artifact " .. path .. " (run scripts/export_interchange.sh first)")
    end
    local ok, artifact = pcall(CanonicalJSON.decode, bytes)
    if not ok then
      error("cannot decode level artifact " .. path .. ": " .. tostring(artifact))
    end
    if artifact.motion ~= nil and artifact.motion ~= "static" then
      error("level artifact " .. path .. " is not static (motion="
        .. tostring(artifact.motion) .. "); M2 captures support static levels only")
    end
    local hash = sha256_file(path)
    if not hash then error("cannot hash level artifact " .. path) end
    artifacts[#artifacts + 1] = {
      name = name,
      path = path,
      artifact = artifact,
      sha256 = hash,
    }
  end
  return artifacts
end

-- ===========================================================================
-- RNG sequences
-- ===========================================================================

local function verify_seed_anchors()
  local g0 = love.math.newRandomGenerator(0)
  local first = g0:random(1, 100)
  local state0 = g0:getState()
  if first ~= 22 or state0 ~= "0x5e15348974525b7a" then
    error(string.format("RNG seed-0 anchor failed: first=%s state=%s", tostring(first), tostring(state0)))
  end

  local g = love.math.newRandomGenerator(345)
  local draws = {}
  for i = 1, 8 do draws[i] = g:random(1, 10) end
  local expected = { 4, 7, 2, 9, 1, 2, 5, 10 }
  for i = 1, 8 do
    if draws[i] ~= expected[i] then
      error(string.format("RNG seed-345 anchor failed at draw %d: %d ~= %d", i, draws[i], expected[i]))
    end
  end
  local state = g:getState()
  if state ~= "0x7837ac8e69b05bb3" then
    error("RNG seed-345 anchor state failed: " .. state)
  end
end

local function capture_rng_sequences(seeds)
  local sequences = array({})
  local states = array({})
  for _, seed in ipairs(seeds) do
    local gen = love.math.newRandomGenerator(seed)
    local ops = array({})
    local results = array({})
    for _, op in ipairs(RNG_SEQUENCE_OPS) do
      ops[#ops + 1] = op_record(op)
      draw_into(gen, op, results)
    end
    sequences[#sequences + 1] = { seed = seed, ops = ops, results = results }

    local state_gen = love.math.newRandomGenerator(seed)
    local draws = array({ op_record({ kind = "random", lo = 1, hi = 10, count = 8 }) })
    for _ = 1, 8 do state_gen:random(1, 10) end
    local state = state_gen:getState()
    local bits = array({})
    for _ = 1, 4 do bits[#bits + 1] = float_bits_hex(state_gen:random()) end
    states[#states + 1] = {
      seed = seed,
      draws = draws,
      state = state,
      next = { kind = "random01", count = 4, bits_hex = bits },
    }
  end
  return sequences, states
end

local function capture_set_state_entries()
  local entries = array({})

  local allowed = "0x7837ac8e69b05bb3"
  local gen = love.math.newRandomGenerator(0)
  gen:setState(allowed)
  local op = { kind = "random", lo = 1, hi = 10, count = 4 }
  local results = array({})
  draw_into(gen, op, results)
  entries[#entries + 1] = {
    state = allowed,
    ["then"] = op_record(op),
    results = results,
    state_after = gen:getState(),
  }

  local anchor0 = "0x5e15348974525b7a"
  local gen0 = love.math.newRandomGenerator(0)
  gen0:setState(anchor0)
  local op0 = { kind = "random", lo = 1, hi = 100, count = 3 }
  local results0 = array({})
  draw_into(gen0, op0, results0)
  entries[#entries + 1] = {
    state = anchor0,
    ["then"] = op_record(op0),
    results = results0,
    state_after = gen0:getState(),
  }

  local bits_gen = love.math.newRandomGenerator(0)
  bits_gen:setState(allowed)
  local bits = array({})
  for _ = 1, 4 do bits[#bits + 1] = float_bits_hex(bits_gen:random()) end
  entries[#entries + 1] = {
    state = allowed,
    ["then"] = op_record({ kind = "random01", count = 4 }),
    results = bits,
    state_after = bits_gen:getState(),
  }
  return entries
end

local function rng_record(source, seeds)
  verify_seed_anchors()
  local sequences, states = capture_rng_sequences(seeds)
  local anchors = array({
    { seed = 0, first_random_1_100 = 22, state = "0x5e15348974525b7a" },
    {
      seed = 345,
      first_random_1_10 = 4,
      draws = array({ 4, 7, 2, 9, 1, 2, 5, 10 }),
      state = "0x7837ac8e69b05bb3",
    },
  })
  return {
    format = "peggle.rng_fixtures",
    schema_version = 1,
    source = source,
    sequences = sequences,
    states = states,
    set_state = capture_set_state_entries(),
    seed_anchors = anchors,
  }
end

local function filter_rng_record(record, id_filter)
  if id_filter == nil or id_filter == true then return record end
  local wanted = tostring(id_filter)
  local function keep(seed)
    return wanted == tostring(seed) or wanted == ("seed-" .. tostring(seed))
  end
  local out = {}
  for key, value in pairs(record) do out[key] = value end
  out.sequences = array({})
  for _, entry in ipairs(record.sequences) do
    if keep(entry.seed) then out.sequences[#out.sequences + 1] = entry end
  end
  out.states = array({})
  for _, entry in ipairs(record.states) do
    if keep(entry.seed) then out.states[#out.states + 1] = entry end
  end
  return out
end

-- ===========================================================================
-- Peg-color initialization
-- ===========================================================================

-- Runs Engine:setupLevel with newRandomGenerator monkeypatched so the real
-- PegColors generator instance is retained for getState().
local function setup_level_with_rng(level_name)
  local engine = Engine.new({})
  engine.headless = true
  engine.last_shot_replay_path = "/dev/null"
  local captured
  local original = love.math.newRandomGenerator
  love.math.newRandomGenerator = function(...)
    captured = original(...)
    return captured
  end
  local ok, err = pcall(function() engine:setupLevel(level_name) end)
  love.math.newRandomGenerator = original
  if not ok then error(err, 0) end
  if captured == nil then
    error("PegColors did not create a RandomGenerator for " .. level_name)
  end
  return engine, captured
end

local function realized_type_counts(pegs)
  local counts = { blue = 0, green = 0, purple = 0, red = 0 }
  for _, p in ipairs(pegs) do
    counts[p.type] = (counts[p.type] or 0) + 1
  end
  return counts
end

local function capture_color_level(info)
  local level_name = info.name
  local artifact = info.artifact

  -- Real record: setupLevel -> resetTurn (first promotion), untouched.
  local engine, gen = setup_level_with_rng(level_name)
  local peg_types = array({})
  for _, p in ipairs(engine.pegs) do peg_types[#peg_types + 1] = p.type end
  local counts = realized_type_counts(engine.pegs)
  for _, key in ipairs(ARRAY_KEYS) do
    if counts[key] ~= artifact.type_counts[key] then
      error(string.format("peg_colors %s: realized %s count %d != artifact %d",
        level_name, key, counts[key], artifact.type_counts[key]))
    end
  end

  local queue_after_init_raw = ids_of(purple_queue_refs())
  local rng_state_after_init = gen:getState()
  engine:resetTurn()
  local active_after_first = peg_ids(PegColors.get_active_purples())
  local queue_after_first = ids_of(purple_queue_refs())
  local peg_types_after_first = array({})
  for _, p in ipairs(engine.pegs) do peg_types_after_first[#peg_types_after_first + 1] = p.type end
  local rng_state_after_first = gen:getState()

  local promoted = {}
  for _, id in ipairs(active_after_first) do promoted[id] = true end
  local expected_queue = array({})
  for _, id in ipairs(queue_after_init_raw) do
    if not promoted[id] then expected_queue[#expected_queue + 1] = id end
  end
  if #expected_queue ~= #queue_after_first then
    error("peg_colors " .. level_name .. ": queue after first promotion has unexpected size")
  end
  for i = 1, #expected_queue do
    if expected_queue[i] ~= queue_after_first[i] then
      error("peg_colors " .. level_name .. ": queue after first promotion mismatch at index " .. i)
    end
  end

  -- Queue order on a separate fresh setup by repeated promotion (each call
  -- reverts the previous active and promotes the next queue front).
  setup_level_with_rng(level_name)
  local queue_order = array({})
  while PegColors.get_purple_queue_size() > 0 do
    PegColors.assign_next_purple_pegs()
    for _, p in ipairs(PegColors.get_active_purples()) do
      queue_order[#queue_order + 1] = p.original_index
    end
  end
  if #queue_order ~= #queue_after_init_raw then
    error("peg_colors " .. level_name .. ": queue order length mismatch")
  end
  for i = 1, #queue_order do
    if queue_order[i] ~= queue_after_init_raw[i] then
      error("peg_colors " .. level_name .. ": queue order mismatch at index " .. i)
    end
  end

  -- Scripted rounds on a third fresh setup. Keep up to three blue pegs out of
  -- the queue by marking the rest hit; after the kept pegs are promoted the
  -- queue drains empty and the next call rebuilds it from the survivors
  -- (consuming the shuffle's RNG draws when at least two survive).
  local engine_c, gen_c = setup_level_with_rng(level_name)
  local queue_refs = purple_queue_refs()
  local total = #queue_refs
  local keep = total < 3 and total or 3
  local mark = array({})
  for i = keep + 1, total do
    queue_refs[i].hit = true
    mark[#mark + 1] = queue_refs[i].original_index
  end

  local rounds = array({})
  local function do_round(mark_hit)
    local pre_queue = purple_queue_refs()
    local all_hit = true
    for _, p in ipairs(pre_queue) do
      if not p.hit then all_hit = false end
    end
    local survivors = 0
    for _, p in ipairs(engine_c.pegs) do
      if p.type == "blue" and not p.hit then survivors = survivors + 1 end
    end
    local queue_before = ids_of(pre_queue)
    local active_before = ids_of(PegColors.get_active_purples())
    local rng_before = gen_c:getState()
    PegColors.assign_next_purple_pegs()
    rounds[#rounds + 1] = {
      mark_hit = mark_hit,
      queue_before = queue_before,
      active_before = active_before,
      rng_state_before = rng_before,
      rebuilt = all_hit and survivors > 0,
      active = ids_of(PegColors.get_active_purples()),
      queue = ids_of(purple_queue_refs()),
      rng_state = gen_c:getState(),
    }
  end

  if total == 0 then
    do_round(array({}))
  else
    for round = 1, keep + 1 do
      do_round(round == 1 and mark or array({}))
    end
  end

  local rebuilt_rounds = 0
  for _, round in ipairs(rounds) do
    if round.rebuilt then rebuilt_rounds = rebuilt_rounds + 1 end
  end
  if total > 0 and rebuilt_rounds == 0 then
    error("peg_colors " .. level_name .. ": the scripted rounds never exercised a rebuild")
  end

  return {
    level = level_name,
    level_sha256 = info.sha256,
    level_seed = artifact.level_seed,
    type_counts = {
      blue = artifact.type_counts.blue,
      green = artifact.type_counts.green,
      purple = artifact.type_counts.purple,
      red = artifact.type_counts.red,
    },
    peg_types = peg_types,
    queue_after_init = queue_order,
    active_after_first_promotion = active_after_first,
    queue_after_first_promotion = queue_after_first,
    peg_types_after_first_promotion = peg_types_after_first,
    rng_state_after_init = rng_state_after_init,
    rng_state_after_first_promotion = rng_state_after_first,
    rounds = rounds,
  }
end

local function colors_record(source, artifacts)
  local levels = array({})
  for _, info in ipairs(artifacts) do
    levels[#levels + 1] = capture_color_level(info)
  end
  return {
    format = "peggle.peg_colors_fixtures",
    schema_version = 1,
    source = source,
    levels = levels,
  }
end

local function filter_colors_record(record, level_filter)
  if level_filter == nil or level_filter == true then return record end
  local out = {}
  for key, value in pairs(record) do out[key] = value end
  out.levels = array({})
  for _, entry in ipairs(record.levels) do
    if entry.level == level_filter then out.levels[#out.levels + 1] = entry end
  end
  return out
end

-- ===========================================================================
-- Ready-to-aim checkpoints
-- ===========================================================================

local function build_ready_to_aim(level_name, balls)
  local engine = Engine.new({})
  engine.headless = true
  engine.last_shot_replay_path = "/dev/null"
  local captured
  local original = love.math.newRandomGenerator
  love.math.newRandomGenerator = function(...)
    captured = original(...)
    return captured
  end
  local ok, err = pcall(function() engine:setupLevel(level_name) end)
  love.math.newRandomGenerator = original
  if not ok then error(err, 0) end
  if captured == nil then
    error("PegColors did not create a RandomGenerator for " .. level_name)
  end

  local initial_balls = nil
  if balls > 1 then
    initial_balls = {}
    for i = 1, balls do
      local x = (i / (balls + 1)) * LevelManager.virtual_width
      initial_balls[#initial_balls + 1] = Ball.new(x, 50)
    end
  end
  engine:resetTurn(initial_balls)
  return engine, captured
end

local function serialize_peg(peg)
  local shape = peg.shape or "circle"
  local out = {
    id = peg.original_index,
    type = peg.type,
    hit = peg.hit == true,
    x = peg.x,
    y = peg.y,
    base_x = peg.base_x,
    base_y = peg.base_y,
    shape = shape,
  }
  if shape == "circle" then
    out.radius = peg.radius
  elseif shape == "rectangle" then
    out.width = peg.width
    out.height = peg.height
    out.angle = peg.angle
  elseif shape == "annular" then
    out.r_in = peg.r_in
    out.r_out = peg.r_out
    out.theta_start = peg.theta_start
    out.theta_end_abs = peg.theta_end_abs
    out.segments = peg.segments
  end
  if peg.line then
    out.line = {
      id = peg.line.id,
      index = peg.line.index,
      count = peg.line.count,
      closed = peg.line.closed == true,
      gap = peg.line.gap,
    }
  end
  if peg.hit then
    out.hit_order = peg.hit_order
    out.multiplier_at_hit = peg.multiplier_at_hit
  end
  return out
end

local function serialize_ball(ball)
  return {
    id = ball.id,
    x = ball.x,
    y = ball.y,
    prev_x = ball.prev_x,
    prev_y = ball.prev_y,
    vx = ball.vx,
    vy = ball.vy,
    launched = ball.launched == true,
    radius = ball.radius,
  }
end

local function serialize_bucket(bucket)
  return {
    x = bucket.x,
    prev_x = bucket.prev_x,
    top = bucket.top,
    hole = bucket.hole,
    edge = bucket.edge,
    height = bucket.height,
    phase = bucket.phase,
  }
end

local function serialize_fever_buckets(fever)
  local buckets = array({})
  for _, b in ipairs(fever.buckets) do
    buckets[#buckets + 1] = { x = b.x, width = b.width, value = b.value }
  end
  local dividers = array({})
  for _, d in ipairs(fever.dividers) do
    dividers[#dividers + 1] = { x = d.x, y = d.y, radius = d.radius, is_divider = d.is_divider == true }
  end
  return {
    top = fever.top,
    target_top = fever.target_top,
    height = fever.height,
    animating = fever.animating == true,
    buckets = buckets,
    dividers = dividers,
  }
end

local function serialize_trackers(engine)
  local style = engine.styleShots
  local ball = engine.ballState
  local slide = engine.slideInversion
  return {
    style_shots = {
      last_impact = wrap(style.last_impact),
      qualifying_streak = wrap(style.qualifying_streak),
      last_qualifying_seq = wrap(style.last_qualifying_seq),
      bucket_bounced = wrap(style.bucket_bounced),
      bounced_after_bucket = wrap(style.bounced_after_bucket),
      side_wall_hit = wrap(style.side_wall_hit),
      hit_any_peg = wrap(style.hit_any_peg),
      awarded = wrap(style.awarded),
      slide_runs = wrap(style.slide_runs),
      slide_awarded = wrap(style.slide_awarded),
    },
    ball_state = {
      idle = wrap(ball.idle),
      idle_timer = wrap(ball.idle_timer),
      reacted = wrap(ball.reacted),
      all_idle_latch = ball.all_idle_latch == true,
      no_score_timer = ball.no_score_timer,
      no_score_timeout_fired = ball.no_score_timeout_fired == true,
    },
    slide_inversion = {
      line_hits = wrap(slide.line_hits),
      hit_seen = wrap(slide.hit_seen),
      removed = wrap(slide.removed),
      track = wrap(slide.track),
    },
  }
end

local function capture_checkpoint(spec, source)
  local artifact = spec.artifact
  local engine, gen = build_ready_to_aim(spec.level, spec.balls)
  local level_seed = artifact.level_seed
  if level_seed == nil then error("checkpoint " .. spec.id .. ": missing level_seed") end

  local used_ids = {}
  for id in pairs(engine.used_ball_ids) do used_ids[#used_ids + 1] = id end
  table.sort(used_ids)
  local used_out = array({})
  for _, id in ipairs(used_ids) do used_out[#used_out + 1] = id end

  local pegs = array({})
  for _, p in ipairs(engine.pegs) do pegs[#pegs + 1] = serialize_peg(p) end

  local balls = array({})
  for _, b in ipairs(engine.active_balls) do balls[#balls + 1] = serialize_ball(b) end

  local turn_pegs_hit = array({})
  for _, p in ipairs(engine.turnPegsHit) do turn_pegs_hit[#turn_pegs_hit + 1] = p.original_index end

  local match_players = array({
    { score = 0, balls = Config.starting_balls, bucket_hits = 0 },
    { score = 0, balls = Config.starting_balls, bucket_hits = 0 },
  })

  return {
    format = "peggle.checkpoint",
    schema_version = 1,
    boundary = "ready_to_aim",
    provenance = {
      reference_revision = source.reference_revision,
      reference_tree = source.reference_tree,
      config_sha256 = source.config_sha256,
      level_sha256 = spec.sha256,
    },
    engine = {
      step_id = engine.sim_step_id,
      shot_id = engine.shot_id,
      level_name = spec.level,
      is_fever = engine.isFever == true,
      current_multiplier = engine.currentMultiplier,
      hit_counter = engine.hitCounter,
      total_red_pegs = engine.totalRedPegs,
      red_pegs_hit_amount = engine.redPegsHitAmount,
      bonus_score = engine.bonusScore,
      style_score = engine.styleScore,
      pegs = pegs,
      balls = balls,
      bucket = serialize_bucket(engine.bucket),
      next_ball_id = engine.next_ball_id,
      used_ball_ids = used_out,
      turn_pegs_hit = turn_pegs_hit,
      clearing = object({
        active = engine.clearQueue ~= nil,
        is_end_of_turn = engine.clearingIsEndOfTurn == true,
        timer = engine.clearTimer,
      }),
      fever_buckets = serialize_fever_buckets(engine.feverBuckets),
    },
    rng = {
      generator = "love.math.newRandomGenerator",
      seed = level_seed,
      state_b64 = love.data.encode("string", "base64", gen:getState()),
    },
    purple_queue = object({
      queue = peg_ids(purple_queue_refs()),
      active = peg_ids(PegColors.get_active_purples()),
    }),
    trackers = serialize_trackers(engine),
    match = {
      mode = "solo",
      players = match_players,
      current_player_index = 1,
      shared_bucket_hits = 0,
      game_over = false,
    },
  }
end

local function checkpoint_specs(artifacts)
  local specs = {}
  for _, info in ipairs(artifacts) do
    specs[#specs + 1] = {
      id = info.name,
      level = info.name,
      balls = 1,
      file = info.name .. ".v1.json",
      artifact = info.artifact,
      sha256 = info.sha256,
    }
  end
  for _, info in ipairs(artifacts) do
    if info.name == "slide" then
      specs[#specs + 1] = {
        id = "slide.multiball3",
        level = "slide",
        balls = 3,
        file = "slide.multiball3.v1.json",
        artifact = info.artifact,
        sha256 = info.sha256,
      }
      break
    end
  end
  return specs
end

-- ===========================================================================
-- Entry point
-- ===========================================================================

local function collect_seeds(artifacts)
  local seen = {}
  local seeds = {}
  local function add(seed)
    if seed ~= nil and not seen[seed] then
      seen[seed] = true
      seeds[#seeds + 1] = seed
    end
  end
  for _, seed in ipairs(FIXED_SEEDS) do add(seed) end
  for _, info in ipairs(artifacts) do add(info.artifact.level_seed) end
  table.sort(seeds)
  return seeds
end

local function id_matches_seed(id, seeds)
  for _, seed in ipairs(seeds) do
    if tostring(id) == tostring(seed) or tostring(id) == ("seed-" .. tostring(seed)) then
      return true
    end
  end
  return false
end

function M.run(opts)
  local args = opts.args
  local source = source_provenance(args)

  local levels = opts.levels or {}
  if #levels == 0 then
    levels = discover_levels(opts.repo_root, opts.read_file_bytes)
  end
  if #levels == 0 then
    error("no static levels found; pass --levels or run scripts/export_interchange.sh")
  end
  local artifacts = load_artifacts(opts.repo_root, levels, opts.read_file_bytes, opts.sha256_file)

  local levels_out = {}
  for _, info in ipairs(artifacts) do levels_out[#levels_out + 1] = info.name end

  local all = args["m2-capture"] == true
  local ran_section = false

  if all or args["m2-rng"] then
    local seeds = collect_seeds(artifacts)
    local id_filter = args["id"]
    if id_filter ~= nil and id_filter ~= true and not id_matches_seed(id_filter, seeds) then
      if args["m2-rng"] and not all then
        error("no RNG sequence matches --id " .. tostring(id_filter))
      end
      print("m2 capture: no RNG sequence matches --id " .. tostring(id_filter) .. "; skipped")
    else
      local record = rng_record(source, seeds)
      local path = opts.rng_out .. "/rng_sequences.v1.json"
      emit(opts, path, record, id_filter ~= nil and id_filter ~= true,
        function(rec) return filter_rng_record(rec, id_filter) end)
      ran_section = true
    end
  end

  if all or args["m2-peg-colors"] then
    local level_filter = args["level"]
    local matched = level_filter == nil or level_filter == true
    if not matched then
      for _, info in ipairs(artifacts) do
        if info.name == level_filter then matched = true end
      end
    end
    if not matched then
      if args["m2-peg-colors"] and not all then
        error("no peg-color record matches --level " .. tostring(level_filter))
      end
      print("m2 capture: no peg-color record matches --level " .. tostring(level_filter) .. "; skipped")
    else
      local record = colors_record(source, artifacts)
      local path = opts.rng_out .. "/peg_colors.v1.json"
      emit(opts, path, record, level_filter ~= nil and level_filter ~= true,
        function(rec) return filter_colors_record(rec, level_filter) end)
      ran_section = true
    end
  end

  if all or args["m2-checkpoints"] then
    local id_filter = args["id"]
    local level_filter = args["level"]
    local selected = {}
    for _, spec in ipairs(checkpoint_specs(artifacts)) do
      local keep = true
      if id_filter ~= nil and id_filter ~= true and spec.id ~= id_filter then keep = false end
      if level_filter ~= nil and level_filter ~= true and spec.level ~= level_filter then keep = false end
      if keep then selected[#selected + 1] = spec end
    end
    if #selected == 0 then
      if args["m2-checkpoints"] and not all then
        error("no checkpoints selected")
      end
      print("m2 capture: no checkpoint matches the filters; skipped")
    else
      for _, spec in ipairs(selected) do
        local record = capture_checkpoint(spec, source)
        emit(opts, opts.checkpoints_out .. "/" .. spec.file, record, false, nil)
      end
      ran_section = true
    end
  end

  if not ran_section then
    error("m2 capture: no records selected")
  end

  print(string.format("m2 capture: levels=%s %s", table.concat(levels_out, ","),
    args["check"] and "verified" or "written"))
end

return M
