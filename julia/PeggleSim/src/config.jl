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

struct PegTypeConfig
    color::NTuple{3,Float64}
    value::Float64
end

struct SimConfig
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
    bucket_edge::Float64
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
    source_sha256::String
end

# The exact key set of the pinned config artifact, in artifact (alphabetical)
# order. The loader fails when the artifact gains, loses, or renames a value.
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
    :bucket_edge,
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

function _check_config_keys(values::AbstractDict)
    for key in keys(values)
        Symbol(key) in CONFIG_VALUE_KEYS ||
            throw(ArgumentError(
                "config: unknown value key '$(key)'; the pinned reference config advanced"))
    end
    for key in CONFIG_VALUE_KEYS
        haskey(values, String(key)) ||
            throw(ArgumentError("config: missing value key '$(key)'"))
    end
    return nothing
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
    _check_config_keys(values)

    f(k) = as_f64(values[String(k)], String(k))
    i(k) = as_int(values[String(k)], String(k))
    b(k) = as_bool(values[String(k)], String(k))
    s(k) = as_string(values[String(k)], String(k))

    parsed = (
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
        bucket_edge = f(:bucket_edge),
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
        source_sha256 = source_sha256,
    )
    return SimConfig(parsed...)
end

config_source_sha256(c::SimConfig)::String = c.source_sha256
