# Typed view of interchange/config.v1.json.
#
# Every value under the artifact's `values` object has an explicit field with
# the same key name (the frozen M2 API: `c.fixed_dt`, `c.gravity`, ...).
# Nested tables become typed structs/NamedTuples:
#
#   * `peg_types`       -> NamedTuple{(:blue,:green,:purple,:red)} of PegTypeConfig
#   * `background_color` -> NTuple{3,Float64}
#   * `ball_color`, `bucket_color` -> NTuple{3,Float64}
#
# The loader rejects unknown (or missing) value keys: an unknown config value
# means the pinned reference advanced and the port must be revisited.
#
# Gameplay rule set. Some dev-tree revisions after the pin changed gameplay
# rules together with the config keys that parameterize them. The config
# artifact therefore selects the rules, and `load_config` resolves that
# selection ONCE into the explicit `SimConfig.rules` field; the per-step code
# branches on that field (an enum compare), never on dictionary lookups.
#
#   RULES_CLASSIC      pinned d17f6e7 .. peggle_evolved d40abc9. Selected by
#                      `bucket_edge` (and none of the 10ee3a0 bucket keys):
#                      three-rectangle bucket, instant catch removal, two
#                      green-power balls.
#   RULES_RAMP_BUCKET  peggle_evolved 10ee3a0 ("Reshape bucket with side
#                      ramps, hold shot end after catch, fix multiball").
#                      Selected by the presence of all of `bucket_rim_width`,
#                      `bucket_rim_height`, `bucket_ramp_slope_deg` and
#                      `bucket_catch_hold` (and no `bucket_edge`): rimmed
#                      bucket with outer ramps and swept collision, caught
#                      balls fall out of view before removal, shot end held
#                      for `bucket_catch_hold`, one green-power ball.
#
# A config carrying keys of both sets, or only part of the 10ee3a0 set, is
# rejected: it matches no Lua revision the port knows. See
# wiki/context/bucket-ramps.md.
@enum RuleSet::UInt8 RULES_CLASSIC RULES_RAMP_BUCKET

struct PegTypeConfig
    color::NTuple{3,Float64}
    value::Float64
end

struct SimConfig
    shooter_y::Float64
    ceiling_y::Float64
    shooter_top_gap::Float64
    aim_extra_angle::Float64
    aim_angle_limit::Float64
    aim_discretization_steps::Int
    aim_fine_adjust_speed::Float64
    aim_wheel_adjust::Float64
    annular_cap_epsilon::Float64
    background_color::NTuple{3,Float64}
    ball_ball_collisions::Bool
    ball_ball_restitution::Float64
    ball_color::NTuple{3,Float64}
    ball_radius::Float64
    ball_still_speed::Float64
    ball_wake_speed_multiplier::Float64
    bounce_min_normal_speed::Float64
    bucket_accel_multiplier::Float64
    bucket_bonus::Float64
    bucket_color::NTuple{3,Float64}
    bucket_edge::Float64            # RULES_CLASSIC only (0.0 under RULES_RAMP_BUCKET)
    bucket_height::Float64
    bucket_hole::Float64
    bucket_incremental_base::Float64
    bucket_margin::Float64
    circuit_speedup_multiplier::Float64
    clear_no_score_time::Float64
    clear_still_time::Float64
    current_level_name::String
    default_peg_type::Symbol
    double_long_shot_points::Float64
    fall_out_margin::Float64
    fever_bucket_raise_speed::Float64
    fixed_dt::Float64
    fullscreen::Bool
    gravity::Float64
    graze_tolerance::Float64
    launch_speed::Float64
    long_shot_distance::Float64
    long_shot_points::Float64
    lucky_bounce_points::Float64
    off_the_wall_min_distance::Float64
    off_the_wall_points::Float64
    overlap_push_margin::Float64
    peg_lit_blend::Float64
    peg_radius::Float64
    peg_rect_height::Float64
    peg_rect_width::Float64
    peg_types::NamedTuple{(:blue, :green, :purple, :red),NTuple{4,PegTypeConfig}}
    peg_vanish_interval::Float64
    purple_pegs_per_turn::Int
    restitution::Float64
    rotation_sweep_arc_px::Float64
    rotation_sweep_max_slices::Int
    safe_t_margin::Float64
    settle_restitution::Float64
    slide_invert_contact_timeout::Float64
    slide_invert_lowest_tie::Int
    slide_invert_tangent_epsilon::Float64
    slide_min_pegs::Int
    slide_points::Float64
    starting_balls::Int
    super_long_shot_distance::Float64
    super_long_shot_points::Float64
    toi_epsilon::Float64
    virtual_height::Float64
    virtual_width::Float64
    wall_damping::Float64
    window_height::Int
    window_width::Int
    # RULES_RAMP_BUCKET keys (0.0 under RULES_CLASSIC, where Lua has no such
    # Config entries and never reads them).
    bucket_catch_hold::Float64
    bucket_ramp_slope_deg::Float64
    bucket_rim_height::Float64
    bucket_rim_width::Float64
    # Resolved once at load (see RuleSet above).
    rules::RuleSet
    # core.lua step (12): math.ceil((Config.bucket_catch_hold or 0) /
    # Config.fixed_dt), a constant per config; 0 under RULES_CLASSIC.
    bucket_catch_hold_steps::Int
    source_sha256::String
end

# The value keys every supported config artifact carries, in artifact
# (alphabetical) order. The loader fails when the artifact gains, loses, or
# renames a value. The bucket-model keys that differ between rule sets are
# listed separately below.
const CONFIG_VALUE_KEYS = (
    :aim_angle_limit,
    :aim_discretization_steps,
    :aim_fine_adjust_speed,
    :aim_wheel_adjust,
    :annular_cap_epsilon,
    :background_color,
    :ball_ball_collisions,
    :ball_ball_restitution,
    :ball_color,
    :ball_radius,
    :ball_still_speed,
    :ball_wake_speed_multiplier,
    :bounce_min_normal_speed,
    :bucket_accel_multiplier,
    :bucket_bonus,
    :bucket_color,
    :bucket_height,
    :bucket_hole,
    :bucket_incremental_base,
    :bucket_margin,
    :circuit_speedup_multiplier,
    :clear_no_score_time,
    :clear_still_time,
    :current_level_name,
    :default_peg_type,
    :double_long_shot_points,
    :fall_out_margin,
    :fever_bucket_raise_speed,
    :fixed_dt,
    :fullscreen,
    :gravity,
    :graze_tolerance,
    :launch_speed,
    :long_shot_distance,
    :long_shot_points,
    :lucky_bounce_points,
    :off_the_wall_min_distance,
    :off_the_wall_points,
    :overlap_push_margin,
    :peg_lit_blend,
    :peg_radius,
    :peg_rect_height,
    :peg_rect_width,
    :peg_types,
    :peg_vanish_interval,
    :purple_pegs_per_turn,
    :restitution,
    :rotation_sweep_arc_px,
    :rotation_sweep_max_slices,
    :safe_t_margin,
    :settle_restitution,
    :slide_invert_contact_timeout,
    :slide_invert_lowest_tie,
    :slide_invert_tangent_epsilon,
    :slide_min_pegs,
    :slide_points,
    :starting_balls,
    :super_long_shot_distance,
    :super_long_shot_points,
    :toi_epsilon,
    :virtual_height,
    :virtual_width,
    :wall_damping,
    :window_height,
    :window_width,
)

# Rule-set selecting keys (see RuleSet). Exactly one of these sets is present.
const CONFIG_CLASSIC_BUCKET_KEYS = (
    :bucket_edge,
)
const CONFIG_RAMP_BUCKET_KEYS = (       # peggle_evolved 10ee3a0
    :bucket_catch_hold,
    :bucket_ramp_slope_deg,
    :bucket_rim_height,
    :bucket_rim_width,
)

# Presentation-only keys added to the dev-tree config after the pin. They may
# be present (dev-tree artifacts) or absent (pinned artifacts); the simulation
# never reads them.
const CONFIG_OPTIONAL_PRESENTATION_KEYS = (
    :peg_border_color, # ec4fcb3: peg outline color, render-only
    :bucket_rim_color, # 10ee3a0: bucket rim color, render-only
)

const CONFIG_OPTIONAL_SHOOTER_KEYS = (:shooter_top_gap, :aim_extra_angle)

aim_angle_limit(c::SimConfig) = c.aim_angle_limit + c.aim_extra_angle

const CONFIG_TOP_LEVEL_KEYS = ("format", "schema_version", "source_sha256", "values")

function _color3(x, what::AbstractString)::NTuple{3,Float64}
    arr = as_array(x, what)
    length(arr) == 3 || throw(ArgumentError("$(what) must have 3 components, got $(length(arr))"))
    return (as_f64(arr[1], "$(what)[1]"),
            as_f64(arr[2], "$(what)[2]"),
            as_f64(arr[3], "$(what)[3]"))
end

function _peg_type_config(x, what::AbstractString)::PegTypeConfig
    d = as_object(x, what)
    return PegTypeConfig(
        _color3(d["color"], "$(what).color"),
        as_f64(d["value"], "$(what).value"),
    )
end

function _peg_types_config(x)::NamedTuple{(:blue, :green, :purple, :red),NTuple{4,PegTypeConfig}}
    d = as_object(x, "peg_types")
    for key in ("blue", "green", "purple", "red")
        haskey(d, key) || throw(ArgumentError("config: peg_types is missing '$(key)'"))
    end
    return (
        blue = _peg_type_config(d["blue"], "peg_types.blue"),
        green = _peg_type_config(d["green"], "peg_types.green"),
        purple = _peg_type_config(d["purple"], "peg_types.purple"),
        red = _peg_type_config(d["red"], "peg_types.red"),
    )
end

function _check_config_keys(values::AbstractDict)::RuleSet
    for key in keys(values)
        (Symbol(key) in CONFIG_VALUE_KEYS ||
         Symbol(key) in CONFIG_CLASSIC_BUCKET_KEYS ||
         Symbol(key) in CONFIG_RAMP_BUCKET_KEYS ||
         Symbol(key) in CONFIG_OPTIONAL_PRESENTATION_KEYS ||
         Symbol(key) in CONFIG_OPTIONAL_SHOOTER_KEYS) ||
            throw(ArgumentError(
                "config: unknown value key '$(key)'; the pinned reference config advanced"))
    end
    for key in CONFIG_VALUE_KEYS
        haskey(values, String(key)) ||
            throw(ArgumentError("config: missing value key '$(key)'"))
    end
    return _select_rules(values)
end

# Resolve the rule set from the bucket keys the artifact carries.
function _select_rules(values::AbstractDict)::RuleSet
    classic = count(k -> haskey(values, String(k)), CONFIG_CLASSIC_BUCKET_KEYS)
    ramp = count(k -> haskey(values, String(k)), CONFIG_RAMP_BUCKET_KEYS)
    if classic == length(CONFIG_CLASSIC_BUCKET_KEYS) && ramp == 0
        return RULES_CLASSIC
    elseif classic == 0 && ramp == length(CONFIG_RAMP_BUCKET_KEYS)
        return RULES_RAMP_BUCKET
    end
    throw(ArgumentError(
        "config: bucket keys match no known rule set: classic needs " *
        "$(collect(CONFIG_CLASSIC_BUCKET_KEYS)) alone, 10ee3a0 needs all of " *
        "$(collect(CONFIG_RAMP_BUCKET_KEYS)) and no bucket_edge"))
end

# core.lua step (12): `math.ceil((Config.bucket_catch_hold or 0) / Config.fixed_dt)`.
function _catch_hold_steps(hold::Float64, fixed_dt::Float64)::Int
    steps = ceil(hold / fixed_dt)
    isfinite(steps) || throw(ArgumentError(
        "config: bucket_catch_hold / fixed_dt must be finite, got $(steps)"))
    return Int(steps)
end

function load_config(path::AbstractString)::SimConfig
    doc = as_object(load_json(path), "config document")
    for key in keys(doc)
        key in CONFIG_TOP_LEVEL_KEYS ||
            throw(ArgumentError("config: unknown top-level key '$(key)'"))
    end
    as_string(doc["format"], "format") == "peggle.config" ||
        throw(ArgumentError("config: format must be peggle.config"))
    as_int(doc["schema_version"], "schema_version") == 1 ||
        throw(ArgumentError("config: unsupported schema_version"))
    source_sha256 = as_string(doc["source_sha256"], "source_sha256")

    values = as_object(doc["values"], "values")
    rules = _check_config_keys(values)
    ramps = rules === RULES_RAMP_BUCKET

    f(k) = as_f64(values[String(k)], String(k))
    i(k) = as_int(values[String(k)], String(k))
    b(k) = as_bool(values[String(k)], String(k))
    s(k) = as_string(values[String(k)], String(k))

    gap = haskey(values, "shooter_top_gap") ? f(:shooter_top_gap) : 0.0
    extra = haskey(values, "aim_extra_angle") ? f(:aim_extra_angle) : 0.0
    isfinite(gap) && gap >= 0 || throw(ArgumentError("config: shooter_top_gap must be finite and nonnegative"))
    isfinite(extra) && extra >= 0 && 0 < f(:aim_angle_limit) + extra < pi ||
        throw(ArgumentError("config: total aim limit must be between 0 and pi, with nonnegative extra room"))

    shooter_y = haskey(values, "shooter_top_gap") ? -gap : 50.0
    parsed = (
        shooter_y = shooter_y,
        ceiling_y = min(0.0, shooter_y - 50.0),
        shooter_top_gap = gap,
        aim_extra_angle = extra,
        aim_angle_limit = f(:aim_angle_limit),
        aim_discretization_steps = i(:aim_discretization_steps),
        aim_fine_adjust_speed = f(:aim_fine_adjust_speed),
        aim_wheel_adjust = f(:aim_wheel_adjust),
        annular_cap_epsilon = f(:annular_cap_epsilon),
        background_color = _color3(values["background_color"], "background_color"),
        ball_ball_collisions = b(:ball_ball_collisions),
        ball_ball_restitution = f(:ball_ball_restitution),
        ball_color = _color3(values["ball_color"], "ball_color"),
        ball_radius = f(:ball_radius),
        ball_still_speed = f(:ball_still_speed),
        ball_wake_speed_multiplier = f(:ball_wake_speed_multiplier),
        bounce_min_normal_speed = f(:bounce_min_normal_speed),
        bucket_accel_multiplier = f(:bucket_accel_multiplier),
        bucket_bonus = f(:bucket_bonus),
        bucket_color = _color3(values["bucket_color"], "bucket_color"),
        bucket_edge = ramps ? 0.0 : f(:bucket_edge),
        bucket_height = f(:bucket_height),
        bucket_hole = f(:bucket_hole),
        bucket_incremental_base = f(:bucket_incremental_base),
        bucket_margin = f(:bucket_margin),
        circuit_speedup_multiplier = f(:circuit_speedup_multiplier),
        clear_no_score_time = f(:clear_no_score_time),
        clear_still_time = f(:clear_still_time),
        current_level_name = s(:current_level_name),
        default_peg_type = Symbol(s(:default_peg_type)),
        double_long_shot_points = f(:double_long_shot_points),
        fall_out_margin = f(:fall_out_margin),
        fever_bucket_raise_speed = f(:fever_bucket_raise_speed),
        fixed_dt = f(:fixed_dt),
        fullscreen = b(:fullscreen),
        gravity = f(:gravity),
        graze_tolerance = f(:graze_tolerance),
        launch_speed = f(:launch_speed),
        long_shot_distance = f(:long_shot_distance),
        long_shot_points = f(:long_shot_points),
        lucky_bounce_points = f(:lucky_bounce_points),
        off_the_wall_min_distance = f(:off_the_wall_min_distance),
        off_the_wall_points = f(:off_the_wall_points),
        overlap_push_margin = f(:overlap_push_margin),
        peg_lit_blend = f(:peg_lit_blend),
        peg_radius = f(:peg_radius),
        peg_rect_height = f(:peg_rect_height),
        peg_rect_width = f(:peg_rect_width),
        peg_types = _peg_types_config(values["peg_types"]),
        peg_vanish_interval = f(:peg_vanish_interval),
        purple_pegs_per_turn = i(:purple_pegs_per_turn),
        restitution = f(:restitution),
        rotation_sweep_arc_px = f(:rotation_sweep_arc_px),
        rotation_sweep_max_slices = i(:rotation_sweep_max_slices),
        safe_t_margin = f(:safe_t_margin),
        settle_restitution = f(:settle_restitution),
        slide_invert_contact_timeout = f(:slide_invert_contact_timeout),
        slide_invert_lowest_tie = i(:slide_invert_lowest_tie),
        slide_invert_tangent_epsilon = f(:slide_invert_tangent_epsilon),
        slide_min_pegs = i(:slide_min_pegs),
        slide_points = f(:slide_points),
        starting_balls = i(:starting_balls),
        super_long_shot_distance = f(:super_long_shot_distance),
        super_long_shot_points = f(:super_long_shot_points),
        toi_epsilon = f(:toi_epsilon),
        virtual_height = f(:virtual_height),
        virtual_width = f(:virtual_width),
        wall_damping = f(:wall_damping),
        window_height = i(:window_height),
        window_width = i(:window_width),
        bucket_catch_hold = ramps ? f(:bucket_catch_hold) : 0.0,
        bucket_ramp_slope_deg = ramps ? f(:bucket_ramp_slope_deg) : 0.0,
        bucket_rim_height = ramps ? f(:bucket_rim_height) : 0.0,
        bucket_rim_width = ramps ? f(:bucket_rim_width) : 0.0,
        rules = rules,
        bucket_catch_hold_steps = ramps ?
            _catch_hold_steps(f(:bucket_catch_hold), f(:fixed_dt)) : 0,
        source_sha256 = source_sha256,
    )
    return SimConfig(parsed...)
end

config_source_sha256(c::SimConfig)::String = c.source_sha256
