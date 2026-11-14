#!/usr/bin/env julia
# Complete Mathematical Level Profiler for Peggle Evolved (PeggleSim)
#
# Implements the 5-Pillar Level Evaluation Model:
#   Pillar I:   Information Theory & Player Agency (Entropy, MI, Controllability, Blahut-Arimoto Empowerment)
#   Pillar II:  Dynamical Systems & Billiard Chaos (Skill Horizon / MI Half-Life, FTLE, Coherent Shot Basins)
#   Pillar III: Single-Turn Tactical Landscape (Red-Safety, Pareto Frontier, Sector Perplexity, Peg Gini)
#   Pillar IV:  Multi-Turn 1v1 Game Theory (Suspense, Surprise, Drama/Comebacks, Balance, Skill Gradient)
#   Pillar V:   Structural Elegance & MDL Efficiency (Waveguide Balance, Symmetry, Behavioral Efficiency)

using JSON
using Printf
using Statistics
using PeggleSim
using PeggleSim: LevelDefinition, SimConfig

# ---------------------------------------------------------------------------
# 1. Information Theory & Blahut-Arimoto Primitives
# ---------------------------------------------------------------------------

function shannon_entropy_bits(probs::AbstractVector{Float64})::Float64
    h = 0.0
    for p in probs
        if p > 1e-15
            h -= p * log2(p)
        end
    end
    return h
end

"""
Compute H(O), H_sigma(O|A), I_sigma(A;O), C_sigma(O) = I(A;O)/H(O), and
Blahut-Arimoto channel capacity (Empowerment) E_sigma = max_{p(a)} I(A;O)
for a deterministic map `outcomes[a]` (a in 1..N_A) under uniform discrete
execution noise of radius `sigma` steps: a_tilde ~ Unif(max(1, a-sigma):min(N_A, a+sigma)).
"""
function compute_channel_metrics(outcomes::Vector{T}, sigma::Int; ba_iters::Int = 25) where {T}
    n_a = length(outcomes)
    # Map distinct outcomes to integer IDs 1..M
    outcome_to_id = Dict{T, Int}()
    ids = Vector{Int}(undef, n_a)
    for (i, o) in enumerate(outcomes)
        id = get!(outcome_to_id, o, length(outcome_to_id) + 1)
        ids[i] = id
    end
    m = length(outcome_to_id)
    if m <= 1
        return (H_O = 0.0, H_O_given_A = 0.0, MI = 0.0, controllability = 0.0,
                empowerment = 0.0, num_outcomes = m)
    end

    # Sparse transition rows: for each action a, list of (outcome_id, prob)
    rows = Vector{Vector{Tuple{Int, Float64}}}(undef, n_a)
    counts = Dict{Int, Int}()
    p_o_unif = zeros(Float64, m)
    h_cond_sum = 0.0

    for a in 1:n_a
        lo = max(1, a - sigma)
        hi = min(n_a, a + sigma)
        len = hi - lo + 1
        empty!(counts)
        for at in lo:hi
            oid = ids[at]
            counts[oid] = get(counts, oid, 0) + 1
        end
        row = Vector{Tuple{Int, Float64}}(undef, length(counts))
        idx = 1
        h_a = 0.0
        for (oid, c) in counts
            w = c / len
            row[idx] = (oid, w)
            idx += 1
            p_o_unif[oid] += w / n_a
            if w > 1e-15
                h_a -= w * log2(w)
            end
        end
        rows[a] = row
        h_cond_sum += h_a
    end

    H_O = shannon_entropy_bits(p_o_unif)
    H_O_given_A = h_cond_sum / n_a
    MI = max(0.0, H_O - H_O_given_A)
    controllability = H_O > 1e-12 ? clamp(MI / H_O, 0.0, 1.0) : 0.0

    # Blahut-Arimoto algorithm for exact Empowerment E_sigma = max_{p(a)} I(A; O)
    p_a = fill(1.0 / n_a, n_a)
    q_o = zeros(Float64, m)
    r_a = zeros(Float64, n_a)
    for _ in 1:ba_iters
        fill!(q_o, 0.0)
        for a in 1:n_a
            pa = p_a[a]
            for (oid, w) in rows[a]
                q_o[oid] += pa * w
            end
        end
        # Compute KL divergence D(W(.|a) || q_o) in bits for each a
        z = 0.0
        for a in 1:n_a
            kl = 0.0
            for (oid, w) in rows[a]
                if w > 1e-15 && q_o[oid] > 1e-15
                    kl += w * log2(w / q_o[oid])
                end
            end
            r_a[a] = p_a[a] * exp2(kl)
            z += r_a[a]
        end
        if z > 0.0
            for a in 1:n_a
                p_a[a] = r_a[a] / z
            end
        end
    end
    # Final capacity evaluation
    fill!(q_o, 0.0)
    h_cond_opt = 0.0
    for a in 1:n_a
        pa = p_a[a]
        h_a = 0.0
        for (oid, w) in rows[a]
            q_o[oid] += pa * w
            if w > 1e-15
                h_a -= w * log2(w)
            end
        end
        h_cond_opt += pa * h_a
    end
    H_O_opt = shannon_entropy_bits(q_o)
    empowerment = max(MI, H_O_opt - h_cond_opt)

    return (H_O = H_O, H_O_given_A = H_O_given_A, MI = MI,
            controllability = controllability, empowerment = empowerment,
            num_outcomes = m)
end

function gini_coefficient(x::AbstractVector{Float64})::Float64
    n = length(x)
    n == 0 && return 0.0
    s = sum(x)
    s <= 1e-12 && return 0.0
    sorted = sort(x)
    num = 0.0
    for (i, val) in enumerate(sorted)
        num += (2 * i - n - 1) * val
    end
    return num / (n * s)
end

# ---------------------------------------------------------------------------
# 2. Tier 0: Static Geometric & Topological Descriptors
# ---------------------------------------------------------------------------

function compute_static_geometry_metrics(level::LevelDefinition)
    pegs = level.pegs
    n = length(pegs)
    vw = level.virtual_width
    vh = level.virtual_height

    n_circle = count(p -> p.shape isa PeggleSim.CircleShape, pegs)
    n_rect = count(p -> p.shape isa PeggleSim.RectangleShape, pegs)
    n_annular = count(p -> p.shape isa PeggleSim.AnnularShape, pegs)

    slide_pegs = count(p -> p.line !== nothing && p.line.gap == 0, pegs)
    line_ids = Set{String}()
    for p in pegs
        p.line !== nothing && push!(line_ids, p.line.id)
    end
    n_lines = length(line_ids)
    f_slide = n > 0 ? slide_pegs / n : 0.0
    # Waveguide-to-Scatterer Balance: 4 * f_slide * (1 - f_slide)
    waveguide_balance = 4.0 * f_slide * (1.0 - f_slide)

    # Nearest-neighbor distances
    nnds = zeros(Float64, n)
    mirror_dists = zeros(Float64, n)
    for i in 1:n
        d_min = Inf
        d_mir = Inf
        xi, yi = pegs[i].x, pegs[i].y
        mxi = vw - xi
        for j in 1:n
            if i != j
                d = hypot(xi - pegs[j].x, yi - pegs[j].y)
                d < d_min && (d_min = d)
            end
            dm = hypot(mxi - pegs[j].x, yi - pegs[j].y)
            dm < d_mir && (d_mir = dm)
        end
        nnds[i] = isfinite(d_min) ? d_min : 0.0
        mirror_dists[i] = isfinite(d_mir) ? d_mir : 0.0
    end
    mean_nnd = n > 1 ? mean(nnds) : 0.0
    std_nnd = n > 1 ? std(nnds) : 0.0
    cv_nnd = mean_nnd > 1e-9 ? std_nnd / mean_nnd : 0.0

    # Horizontal mirror symmetry score in [0, 1]
    symmetry = n > 0 ? mean(exp.(-mirror_dists ./ 25.0)) : 0.0

    # Vertical & 2D spatial entropy (8x8 grid)
    y_bins = zeros(Float64, 8)
    grid_bins = zeros(Float64, 64)
    for p in pegs
        yb = clamp( floor(Int, (p.y / vh) * 8) + 1, 1, 8 )
        xb = clamp( floor(Int, (p.x / vw) * 8) + 1, 1, 8 )
        y_bins[yb] += 1.0 / n
        grid_bins[(yb - 1) * 8 + xb] += 1.0 / n
    end
    vertical_entropy_norm = shannon_entropy_bits(y_bins) / 3.0
    spatial_entropy_norm = shannon_entropy_bits(grid_bins) / 6.0

    # Structural description length proxy K_geom:
    # Each continuous line requires ~6 parameters; each standalone peg requires ~2 parameters.
    standalone_pegs = n - slide_pegs
    k_mdl_params = 6.0 * n_lines + 2.0 * standalone_pegs
    compression_ratio = n > 0 ? (2.0 * n) / max(1.0, k_mdl_params) : 1.0

    return Dict(
        "total_pegs" => n,
        "red_pegs" => level.type_counts.red,
        "green_pegs" => level.type_counts.green,
        "blue_pegs" => level.type_counts.blue,
        "circle_pegs" => n_circle,
        "rect_pegs" => n_rect,
        "annular_pegs" => n_annular,
        "slide_pegs" => slide_pegs,
        "distinct_lines" => n_lines,
        "slide_fraction" => f_slide,
        "waveguide_scatterer_balance" => waveguide_balance,
        "mean_nnd_px" => mean_nnd,
        "cv_nnd" => cv_nnd,
        "mirror_symmetry" => symmetry,
        "vertical_entropy_norm" => vertical_entropy_norm,
        "spatial_2d_entropy_norm" => spatial_entropy_norm,
        "k_mdl_params" => k_mdl_params,
        "structural_compression_ratio" => compression_ratio,
    )
end

# ---------------------------------------------------------------------------
# 3. Tier 1: Exhaustive Single-Turn Trajectory & Information Sweep
# ---------------------------------------------------------------------------

struct CandidateRecord
    aim_index::Int
    steps::Int
    completed::Bool
    reason::String
    score::Float64
    peg_score::Float64
    bonus_score::Float64
    style_score::Float64
    pegs_hit::Int
    reds_hit::Int
    spawned::Int
    bucket_caught::Bool
    midturn_clear::Bool
    slide_removals::Int
    styles_mask::Int
    style_counts::Dict{String, Int}
    scored_peg_seq::Vector{Int}
    bounce_seq::Vector{Int}
    exit_x_bin::Int
    final_x::Float64
    final_y::Float64
    route_signature::Tuple{Int, Int, Int, Int, Int}
    hitset_hash::UInt64
    tactical_signature::Tuple{Bool, Bool, Int, Int}
end

const STYLE_BIT_MAP = Dict(
    "slide" => 1,
    "long_shot" => 2,
    "super_long_shot" => 4,
    "double_long_shot" => 8,
    "off_the_wall" => 16,
    "lucky_bounce" => 32,
)

function run_single_turn_sweep(level::LevelDefinition, config::SimConfig; max_steps::Int = 3600, max_k::Int = 15)
    prov = PeggleSim.campaign_provenance(level)
    ckpt = PeggleSim.build_checkpoint(level, config; mode = Symbol("1v1"), provenance = prov)
    prepared = PeggleSim.prepare_checkpoint(ckpt)
    eng = PeggleSim.shot_engine(prepared; config, level, callbacks = PeggleSim.match_callbacks(), static_geometry = true)

    n_a = config.aim_discretization_steps + 1
    vw = level.virtual_width
    vh = level.virtual_height
    fixed_dt = config.fixed_dt

    records = Vector{CandidateRecord}(undef, n_a)
    for idx in 0:(n_a - 1)
        PeggleSim.reset_shot_engine!(eng, prepared; static_geometry = true)
        PeggleSim.launch!(eng, idx)

        bounce_seq = Int[]
        sizehint!(bounce_seq, max_k)
        last_x = vw / 2
        last_y = 50.0

        while !eng.shot_done && eng.steps_run < max_steps
            PeggleSim.save_previous_state(eng)
            eng.sim.engine.step_id += 1
            PeggleSim.step_simulation!(eng, fixed_dt)
            if !isempty(eng.sim.engine.balls)
                b1 = eng.sim.engine.balls[1]
                last_x = b1.x
                last_y = b1.y
            end
            if length(bounce_seq) < max_k
                for ev in eng.journal.raw
                    length(bounce_seq) >= max_k && break
                    if ev.type == "ball_contacted_peg" && ev.fields.did_bounce === true
                        pid = ev.fields.peg_id
                        pid !== nothing && push!(bounce_seq, Int(pid))
                    elseif ev.type == "ball_contact_wall" && ev.fields.did_bounce === true
                        w = ev.fields.wall
                        wid = w == "left" ? -1 : w == "right" ? -2 : -3
                        push!(bounce_seq, wid)
                    elseif ev.type == "bucket_bounced_ball"
                        push!(bounce_seq, -4)
                    end
                end
            end
            PeggleSim.fever_update!(eng.sim.engine.fever_buckets, fixed_dt, eng.config)
            eng.steps_run += 1
        end

        e = eng.sim.engine
        scored_seq = copy(e.turn_pegs_hit)
        pegs_hit = length(scored_seq)
        reds_hit = count(p -> p.peg_type === :red, eng.turn_peg_refs)
        bucket_caught = eng.last_removal_reason == "bucket_caught"
        exit_bin = bucket_caught ? 0 : clamp(floor(Int, (last_x / vw) * 16) + 1, 1, 16)

        # Compute centroid grid cell (8x8) of hit pegs and coarse (4x4) macro cell
        centroid_cell = 0
        macro_cell = 0
        if pegs_hit > 0
            cx = mean(p.x for p in eng.turn_peg_refs)
            cy = mean(p.y for p in eng.turn_peg_refs)
            xb = clamp(floor(Int, (cx / vw) * 8) + 1, 1, 8)
            yb = clamp(floor(Int, (cy / vh) * 8) + 1, 1, 8)
            centroid_cell = (yb - 1) * 8 + xb
            mxb = clamp(floor(Int, (cx / vw) * 4) + 1, 1, 4)
            myb = clamp(floor(Int, (cy / vh) * 4) + 1, 1, 4)
            macro_cell = (myb - 1) * 4 + mxb
        end
        count_tier = min(5, floor(Int, log2(1 + pegs_hit)))
        exit_quad = bucket_caught ? 0 : clamp(floor(Int, (last_x / vw) * 4) + 1, 1, 4)

        smask = 0
        for (sname, scount) in eng.style_counts
            if scount > 0
                smask |= get(STYLE_BIT_MAP, sname, 0)
            end
        end

        # Macro-route bottleneck representation (~100 states max):
        # (4x4 spatial centroid, hit count log-tier 0..5, exit quadrant 0..4, style indicator 0..1)
        route_sig = (macro_cell, count_tier, exit_quad, smask > 0 ? 1 : 0, reds_hit > 0 ? 1 : 0)
        h_hash = hash(sort(scored_seq))
        tac_sig = (reds_hit > 0, bucket_caught, smask, min(6, pegs_hit ÷ 3))

        records[idx + 1] = CandidateRecord(
            idx,
            eng.steps_run,
            eng.shot_done,
            eng.last_removal_reason === nothing ? (eng.shot_done ? "all_balls_removed" : "step_limit") : eng.last_removal_reason,
            PeggleSim.get_turn_score(eng),
            PeggleSim.get_turn_peg_score(eng),
            e.bonus_score,
            e.style_score,
            pegs_hit,
            reds_hit,
            (e.next_ball_id - 1) - eng.initial_balls,
            bucket_caught,
            eng.midturn_clear_started,
            length(eng.sim.trackers.slide_inversion.removed),
            smask,
            copy(eng.style_counts),
            scored_seq,
            bounce_seq,
            exit_bin,
            last_x,
            last_y,
            route_sig,
            h_hash,
            tac_sig,
        )
    end
    return records
end

function analyze_single_turn(level::LevelDefinition, config::SimConfig, records::Vector{CandidateRecord}; max_k::Int = 15)
    n_a = length(records)
    n_pegs = length(level.pegs)

    # Quantize scores into 16 discrete brackets for information theory
    scores = [r.score for r in records]
    nonzero_scores = filter(>(0.0), scores)
    score_quantiles = isempty(nonzero_scores) ? zeros(Float64, 15) :
        [quantile(nonzero_scores, q) for q in range(0.05, 0.95, length=15)]
    score_bins = [s <= 0.0 ? 0 : searchsortedfirst(score_quantiles, s) for s in scores]

    route_sigs = [r.route_signature for r in records]
    hitset_hashes = [r.hitset_hash for r in records]
    tactical_sigs = [r.tactical_signature for r in records]

    # Multiscale Information-Theoretic Profile across sigma in [1, 2, 5, 10, 20]
    sigmas = [1, 2, 5, 10, 20]
    info_by_sigma = Dict{String, Any}()
    for s in sigmas
        m_route = compute_channel_metrics(route_sigs, s)
        m_hitset = compute_channel_metrics(hitset_hashes, s)
        m_score = compute_channel_metrics(score_bins, s)
        m_tac = compute_channel_metrics(tactical_sigs, s)
        info_by_sigma[string(s)] = Dict(
            "route" => Dict(string(k) => v for (k, v) in pairs(m_route)),
            "hitset" => Dict(string(k) => v for (k, v) in pairs(m_hitset)),
            "score" => Dict(string(k) => v for (k, v) in pairs(m_score)),
            "tactical" => Dict(string(k) => v for (k, v) in pairs(m_tac)),
        )
    end

    # Collision-Indexed Skill Horizon (at sigma = 2 steps)
    # Track both Scored-Peg sequence Y_r and Bounce sequence X_k
    scored_horizon_mi = Float64[]
    scored_horizon_ctrl = Float64[]
    scored_active_frac = Float64[]
    bounce_horizon_mi = Float64[]
    bounce_horizon_ctrl = Float64[]
    bounce_active_frac = Float64[]

    for k in 1:max_k
        yk = [length(r.scored_peg_seq) >= k ? r.scored_peg_seq[k] : 0 for r in records]
        af_y = count(!=(0), yk) / n_a
        cy = compute_channel_metrics(yk, 2)
        push!(scored_horizon_mi, cy.MI)
        push!(scored_horizon_ctrl, cy.controllability)
        push!(scored_active_frac, af_y)

        xk = [length(r.bounce_seq) >= k ? r.bounce_seq[k] : 0 for r in records]
        af_x = count(!=(0), xk) / n_a
        cx = compute_channel_metrics(xk, 2)
        push!(bounce_horizon_mi, cx.MI)
        push!(bounce_horizon_ctrl, cx.controllability)
        push!(bounce_active_frac, af_x)
    end

    # Compute Skill Horizon k_{1/2} (collision index where MI drops below 50% of k=1 MI)
    mi1_bounce = bounce_horizon_mi[1]
    k_half_bounce = Float64(max_k)
    if mi1_bounce > 1e-6
        target = 0.5 * mi1_bounce
        for k in 1:max_k
            if bounce_horizon_mi[k] <= target
                if k == 1
                    k_half_bounce = 1.0
                else
                    prev = bounce_horizon_mi[k - 1]
                    curr = bounce_horizon_mi[k]
                    k_half_bounce = (k - 1) + (prev - target) / max(1e-9, prev - curr)
                end
                break
            end
        end
    else
        k_half_bounce = 0.0
    end

    mi1_scored = scored_horizon_mi[1]
    k_half_scored = Float64(max_k)
    if mi1_scored > 1e-6
        target = 0.5 * mi1_scored
        for k in 1:max_k
            if scored_horizon_mi[k] <= target
                if k == 1
                    k_half_scored = 1.0
                else
                    prev = scored_horizon_mi[k - 1]
                    curr = scored_horizon_mi[k]
                    k_half_scored = (k - 1) + (prev - target) / max(1e-9, prev - curr)
                end
                break
            end
        end
    else
        k_half_scored = 0.0
    end

    auc_bounce_mi = sum(bounce_horizon_mi)
    auc_scored_mi = sum(scored_horizon_mi)

    # Adjacent-Angle Jaccard Distance (Full Hit-Set and Primary 5-Peg Prefix) & Coherent Shot Basins
    jaccard_dists = zeros(Float64, n_a - 1)
    prefix_jaccard_dists = zeros(Float64, n_a - 1)
    hit_sets = [Set(r.scored_peg_seq) for r in records]
    prefix_sets = [Set(r.scored_peg_seq[1:min(5, end)]) for r in records]
    for i in 1:(n_a - 1)
        s1, s2 = hit_sets[i], hit_sets[i + 1]
        if isempty(s1) && isempty(s2)
            jaccard_dists[i] = 0.0
        else
            jaccard_dists[i] = 1.0 - (length(intersect(s1, s2)) / max(1, length(union(s1, s2))))
        end
        p1, p2 = prefix_sets[i], prefix_sets[i + 1]
        if isempty(p1) && isempty(p2)
            prefix_jaccard_dists[i] = 0.0
        else
            prefix_jaccard_dists[i] = 1.0 - (length(intersect(p1, p2)) / max(1, length(union(p1, p2))))
        end
    end

    # Partition into primary coherent basins where prefix_jaccard_dists[i] <= 0.40 and pegs_hit > 0
    basin_widths = Int[]
    knife_edge_angles = 0
    aimable_angles = 0
    dead_angles = count(r -> r.pegs_hit == 0, records)

    i = 1
    while i <= n_a
        if records[i].pegs_hit == 0
            i += 1
            continue
        end
        j = i
        while j < n_a && records[j + 1].pegs_hit > 0 && prefix_jaccard_dists[j] <= 0.40
            j += 1
        end
        w = j - i + 1
        push!(basin_widths, w)
        if w >= 3
            aimable_angles += w
        else
            knife_edge_angles += w
        end
        i = j + 1
    end

    n_aimable_basins = count(>=(3), basin_widths)
    mean_basin_width = isempty(basin_widths) ? 0.0 : mean(basin_widths)
    median_basin_width = isempty(basin_widths) ? 0.0 : median(basin_widths)

    # Peg Exposure & Reachability
    peg_hit_counts = Dict(p.id => 0 for p in level.pegs)
    for r in records
        for pid in r.scored_peg_seq
            if haskey(peg_hit_counts, pid)
                peg_hit_counts[pid] += 1
            end
        end
    end
    peg_probs = [peg_hit_counts[p.id] / n_a for p in level.pegs]
    reachable_peg_frac = n_pegs > 0 ? count(>(0.0), peg_probs) / n_pegs : 0.0
    peg_gini = gini_coefficient(peg_probs)

    # First-contact diversity (which peg is hit first)
    first_pegs = [isempty(r.scored_peg_seq) ? 0 : r.scored_peg_seq[1] for r in records]
    distinct_first_pegs = length(setdiff(Set(first_pegs), Set([0])))

    # 1v1 Tactical & Risk-Reward Landscape under epsilon = 1
    p_red_a = zeros(Float64, n_a)
    mu_score_a = zeros(Float64, n_a)
    mu_net_score_a = zeros(Float64, n_a) # Expected banked score on turn 1 (with red gate)
    p_bucket_a = zeros(Float64, n_a)

    for a in 1:n_a
        lo = max(1, a - 1)
        hi = min(n_a, a + 1)
        len = hi - lo + 1
        sr = 0.0
        ss = 0.0
        snet = 0.0
        sb = 0.0
        for at in lo:hi
            rec = records[at]
            hit_r = rec.reds_hit > 0
            sr += hit_r ? 1.0 : 0.0
            ss += rec.score
            snet += hit_r ? rec.score : 0.0
            sb += rec.bucket_caught ? 1.0 : 0.0
        end
        p_red_a[a] = sr / len
        mu_score_a[a] = ss / len
        mu_net_score_a[a] = snet / len
        p_bucket_a[a] = sb / len
    end

    red_hit_rate = mean(r.reds_hit > 0 for r in records)
    reliable_red_frac = count(>=(0.8), p_red_a) / n_a
    bucket_catch_rate = mean(r.bucket_caught for r in records)

    # Sector Perplexity (Effective Number of Competitive Sectors)
    sectors = PeggleSim.aim_sectors(n_a - 1, 100)
    sector_best_net = [maximum(@view mu_net_score_a[(first(s)+1):(last(s)+1)]) for s in sectors]
    sum_sector = sum(sector_best_net)
    eff_sectors = sum_sector > 1e-9 ? exp2(shannon_entropy_bits(sector_best_net ./ sum_sector)) : 0.0

    # Style-shot rates
    style_rates = Dict{String, Float64}()
    for sname in keys(STYLE_BIT_MAP)
        style_rates[sname] = count(r -> get(r.style_counts, sname, 0) > 0, records) / n_a
    end
    any_style_rate = count(r -> r.styles_mask > 0, records) / n_a

    return Dict(
        "num_angles" => n_a,
        "mean_score" => mean(scores),
        "std_score" => std(scores),
        "max_score" => maximum(scores),
        "median_score" => median(scores),
        "mean_pegs_hit" => mean(r.pegs_hit for r in records),
        "max_pegs_hit" => maximum(r.pegs_hit for r in records),
        "mean_steps" => mean(r.steps for r in records),
        "dead_angle_frac" => dead_angles / n_a,
        "aimable_basin_frac" => aimable_angles / n_a,
        "knife_edge_frac" => knife_edge_angles / n_a,
        "num_aimable_basins" => n_aimable_basins,
        "mean_basin_width_steps" => mean_basin_width,
        "median_basin_width_steps" => median_basin_width,
        "mean_adjacent_jaccard_dist" => mean(jaccard_dists),
        "reachable_peg_frac_turn1" => reachable_peg_frac,
        "distinct_first_hit_pegs" => distinct_first_pegs,
        "peg_hit_gini" => peg_gini,
        "red_hit_rate" => red_hit_rate,
        "reliable_red_frac_eps1" => reliable_red_frac,
        "bucket_catch_rate" => bucket_catch_rate,
        "effective_competitive_sectors" => eff_sectors,
        "any_style_shot_rate" => any_style_rate,
        "style_shot_rates" => style_rates,
        "midturn_clear_rate" => mean(r.midturn_clear for r in records),
        "slide_removal_rate" => mean(r.slide_removals > 0 for r in records),
        "incomplete_shot_rate" => mean(!r.completed for r in records),
        "info_by_sigma" => info_by_sigma,
        "skill_horizon" => Dict(
            "k_half_bounce" => k_half_bounce,
            "k_half_scored" => k_half_scored,
            "auc_bounce_mi_bits" => auc_bounce_mi,
            "auc_scored_mi_bits" => auc_scored_mi,
            "bounce_horizon_mi" => bounce_horizon_mi,
            "bounce_horizon_ctrl" => bounce_horizon_ctrl,
            "bounce_active_frac" => bounce_active_frac,
            "scored_horizon_mi" => scored_horizon_mi,
            "scored_horizon_ctrl" => scored_horizon_ctrl,
            "scored_active_frac" => scored_active_frac,
        ),
    )
end

# ---------------------------------------------------------------------------
# 4. Tier 2: Multi-Turn 1v1 Game-Theoretic Campaign & Skill Ladder
# ---------------------------------------------------------------------------

"""
Evaluate all candidates for 1v1, returning both gross turn scores and red-hit flags.
"""
function evaluate_candidates_1v1!(eng::PeggleSim.ShotEngine, ckpt::PeggleSim.Checkpoint,
                                  scores::Vector{Float64}, hit_reds::Vector{Bool}, max_steps::Int)
    prepared = PeggleSim.prepare_checkpoint(ckpt)
    for i in 0:(length(scores) - 1)
        PeggleSim.reset_shot_engine!(eng, prepared; static_geometry = true)
        PeggleSim.launch!(eng, i)
        PeggleSim.run_shot!(eng; max_steps)
        scores[i + 1] = PeggleSim.get_turn_score(eng)
        hit_reds[i + 1] = any(p -> p.peg_type === :red, eng.turn_peg_refs)
    end
    return nothing
end

"""
Select a shot according to policy:
  - :sector_gross -> standard campaign.jl sector-median policy on gross score
  - :tactical_1v1 -> risk-aware 1v1 utility maximization (accounts for execution noise
                     epsilon and -25% no-red banked-score penalty, selecting from top
                     quartile sectors)
  - :random       -> uniform random legal aim index
"""
function choose_shot(policy::Symbol, scores::Vector{Float64}, hit_reds::Vector{Bool},
                     banked_score::Float64, epsilon::Int, sector_size::Int, rng::PeggleSim.LoveRandom)
    n_a = length(scores)
    if policy === :random
        return PeggleSim.bot_uniform!(rng, 0, n_a - 1)
    elseif policy === :sector_gross
        d = PeggleSim.select_sector_shot(scores, sector_size, rng)
        return d["intended_index"]::Int
    elseif policy === :tactical_1v1
        penalty = floor(banked_score * 0.25)
        utils = Vector{Float64}(undef, n_a)
        for a in 1:n_a
            lo = max(1, a - epsilon)
            hi = min(n_a, a + epsilon)
            len = hi - lo + 1
            u = 0.0
            for at in lo:hi
                u += hit_reds[at] ? scores[at] : -penalty
            end
            utils[a] = u / len
        end
        # Pick best utility in each sector, then filter by >= 75th percentile
        sectors = PeggleSim.aim_sectors(n_a - 1, sector_size)
        winners = [begin
            best = maximum(@view utils[(first(s)+1):(last(s)+1)])
            indices = [i for i in s if utils[i+1] == best]
            (score = best, indices = indices)
        end for s in sectors]
        sorted = sort([w.score for w in winners])
        thresh = sorted[clamp( ceil(Int, 0.75 * length(sorted)), 1, length(sorted) )]
        eligible = [j for j in eachindex(winners) if winners[j].score >= thresh]
        sec = eligible[PeggleSim.bot_uniform!(rng, 1, length(eligible))]
        ties = winners[sec].indices
        return ties[PeggleSim.bot_uniform!(rng, 1, length(ties))]
    else
        error("Unknown policy $policy")
    end
end

function run_custom_1v1_match(initial::PeggleSim.Checkpoint, level::LevelDefinition, config::SimConfig;
                              game_id::Int, base_seed::Int = 20261024,
                              p1_policy::Symbol = :sector_gross, p2_policy::Symbol = :sector_gross,
                              p1_epsilon::Int = 1, p2_epsilon::Int = 1,
                              sector_size::Int = 100, max_steps::Int = 3600, max_turns::Int = 40)
    seeds = [PeggleSim.bot_seed(base_seed, 2 * (game_id - 1) + player) for player in 1:2]
    rngs = PeggleSim.LoveRandom.(seeds)
    live = PeggleSim.shot_engine(initial; config, level, callbacks = PeggleSim.match_callbacks())
    candidate = PeggleSim.shot_engine(initial; config, level, callbacks = PeggleSim.match_callbacks())
    n_a = config.aim_discretization_steps + 1
    scores = zeros(Float64, n_a)
    hit_reds_vec = Vector{Bool}(undef, n_a)
    prov = initial.provenance
    ckpt = initial

    policies = (p1_policy, p2_policy)
    epsilons = (p1_epsilon, p2_epsilon)

    score_history = Tuple{Float64, Float64}[(0.0, 0.0)]
    red_hits_turn = Bool[]
    penalties_turn = Float64[]
    turns = 0
    reason = "turn_limit"
    ever_hit_pegs = Set{Int}()

    for turn in 1:max_turns
        player = live.sim.match.current_player_index
        rng = rngs[player]
        pol = policies[player]
        eps = epsilons[player]

        if pol !== :random
            evaluate_candidates_1v1!(candidate, ckpt, scores, hit_reds_vec, max_steps)
        else
            fill!(scores, 0.0)
            fill!(hit_reds_vec, false)
        end

        banked = live.sim.match.players[player].score
        intended = choose_shot(pol, scores, hit_reds_vec, banked, eps, sector_size, rng)
        offset = PeggleSim.execution_offset!(rng, intended, eps, config.aim_discretization_steps)
        executed = intended + offset

        live.sim.match.players[player].balls -= 1
        PeggleSim.launch!(live, executed)
        PeggleSim.run_shot!(live; max_steps)
        turns += 1
        for pid in live.sim.engine.turn_pegs_hit
            push!(ever_hit_pegs, pid)
        end

        if live.shot_done
            outcome = PeggleSim.finish_match_turn!(live)
            reason = outcome.reason
            push!(red_hits_turn, outcome.hit_red)
            push!(penalties_turn, outcome.penalty)
        else
            reason = "actual_step_limit"
            break
        end

        push!(score_history, (live.sim.match.players[1].score, live.sim.match.players[2].score))
        if reason == "continue" && turn < max_turns
            ckpt = PeggleSim.prepare_match_turn!(live, prov)
        else
            break
        end
    end

    p1_final = live.sim.match.players[1].score
    p2_final = live.sim.match.players[2].score
    winner = live.sim.match.winner === nothing ? (p1_final > p2_final ? 1 : p2_final > p1_final ? 2 : 0) : live.sim.match.winner

    return (
        winner = winner,
        p1_score = p1_score = p1_final,
        p2_score = p2_final,
        turns = turns,
        reason = reason,
        score_history = score_history,
        red_hits_turn = red_hits_turn,
        penalties_turn = penalties_turn,
        ever_hit_pegs = length(ever_hit_pegs),
        shared_bucket_hits = live.sim.match.shared_bucket_hits,
    )
end

"""
Estimate P1 win probability p_t at turn t from score differential delta = B1 - B2
and scale S_scale using a calibrated logistic belief model:
  p_t = 1 / (1 + exp(-delta / S_scale))
Then compute Ely-Frankel-Kamenica (2015) Suspense and Surprise, plus Browne (2010) Drama.
"""
function analyze_1v1_campaigns(level::LevelDefinition, config::SimConfig; n_matches::Int = 8)
    prov = merge(PeggleSim.campaign_provenance(level), (; config_sha256 = config.source_sha256))
    initial = PeggleSim.build_checkpoint(level, config; mode = Symbol("1v1"), provenance = prov)

    # 1. Baseline symmetric 1v1 campaign (Sector-Median vs Sector-Median, eps = 1)
    baseline_matches = Vector{Any}(undef, n_matches)
    Threads.@threads for g in 1:n_matches
        baseline_matches[g] = run_custom_1v1_match(
            initial, level, config; game_id = g,
            p1_policy = :sector_gross, p2_policy = :sector_gross,
            p1_epsilon = 1, p2_epsilon = 1)
    end

    # Compute typical score scale for belief martingale calibration
    final_totals = [max(1000.0, m.p1_score + m.p2_score) for m in baseline_matches]
    score_scale = max(2500.0, 0.25 * median(final_totals))

    lead_changes_list = Float64[]
    comeback_deficits = Float64[]
    is_comeback_win = Bool[]
    suspense_list = Float64[]
    surprise_list = Float64[]

    for m in baseline_matches
        hist = m.score_history
        t_len = length(hist) - 1
        t_len <= 0 && continue

        # Belief sequence p_0, p_1, ..., p_T (with p_T = 1.0 if winner==1, 0.0 if winner==2, 0.5 if tie)
        beliefs = zeros(Float64, length(hist))
        beliefs[1] = 0.5
        for idx in 2:(length(hist) - 1)
            b1, b2 = hist[idx]
            beliefs[idx] = 1.0 / (1.0 + exp(-(b1 - b2) / score_scale))
        end
        beliefs[end] = m.winner == 1 ? 1.0 : m.winner == 2 ? 0.0 : 0.5

        # Surprise: mean |p_{t} - p_{t-1}|
        diffs = [abs(beliefs[idx] - beliefs[idx - 1]) for idx in 2:length(beliefs)]
        push!(surprise_list, mean(diffs))
        # Suspense: RMS of belief increments (martingale volatility proxy)
        push!(suspense_list, sqrt(mean(d^2 for d in diffs)))

        # Lead changes & comeback deficit
        prev_leader = 0
        lc = 0
        max_deficit_ratio = 0.0
        for idx in 2:length(hist)
            b1, b2 = hist[idx]
            leader = b1 > b2 ? 1 : b2 > b1 ? 2 : 0
            if leader != 0 && prev_leader != 0 && leader != prev_leader
                lc += 1
            end
            leader != 0 && (prev_leader = leader)

            if m.winner == 1 && b2 > b1
                max_deficit_ratio = max(max_deficit_ratio, (b2 - b1) / max(b2, 1000.0))
            elseif m.winner == 2 && b1 > b2
                max_deficit_ratio = max(max_deficit_ratio, (b1 - b2) / max(b1, 1000.0))
            end
        end
        push!(lead_changes_list, Float64(lc))
        if m.winner in (1, 2)
            push!(comeback_deficits, max_deficit_ratio)
            push!(is_comeback_win, max_deficit_ratio > 0.05)
        end
    end

    p1_wins = count(m -> m.winner == 1, baseline_matches)
    p2_wins = count(m -> m.winner == 2, baseline_matches)
    ties = count(m -> m.winner == 0, baseline_matches)
    p1_win_rate = (p1_wins + 0.5 * ties) / n_matches
    first_player_balance = 1.0 - 2.0 * abs(p1_win_rate - 0.5)

    # 2. Skill-Ladder Cross-Play Tournament (4 pairs = 8 matches with swapped sides for fairness)
    n_ladder = 4
    tac_vs_sec = zeros(Float64, 2 * n_ladder)
    sec_vs_sloppy = zeros(Float64, 2 * n_ladder)
    sec_vs_rand = zeros(Float64, 2 * n_ladder)

    Threads.@threads for g in 1:n_ladder
        # Tactical (eps=1) vs Sector (eps=1) — side A and side B
        mA = run_custom_1v1_match(initial, level, config; game_id = 100 + g,
                                  p1_policy = :tactical_1v1, p2_policy = :sector_gross, p1_epsilon = 1, p2_epsilon = 1)
        mB = run_custom_1v1_match(initial, level, config; game_id = 100 + g,
                                  p1_policy = :sector_gross, p2_policy = :tactical_1v1, p1_epsilon = 1, p2_epsilon = 1)
        tac_vs_sec[2g - 1] = mA.winner == 1 ? 1.0 : mA.winner == 0 ? 0.5 : 0.0
        tac_vs_sec[2g]     = mB.winner == 2 ? 1.0 : mB.winner == 0 ? 0.5 : 0.0

        # Precise Sector (eps=1) vs Sloppy Sector (eps=10)
        mC = run_custom_1v1_match(initial, level, config; game_id = 200 + g,
                                  p1_policy = :sector_gross, p2_policy = :sector_gross, p1_epsilon = 1, p2_epsilon = 10)
        mD = run_custom_1v1_match(initial, level, config; game_id = 200 + g,
                                  p1_policy = :sector_gross, p2_policy = :sector_gross, p1_epsilon = 10, p2_epsilon = 1)
        sec_vs_sloppy[2g - 1] = mC.winner == 1 ? 1.0 : mC.winner == 0 ? 0.5 : 0.0
        sec_vs_sloppy[2g]     = mD.winner == 2 ? 1.0 : mD.winner == 0 ? 0.5 : 0.0

        # Sector (eps=1) vs Random
        mE = run_custom_1v1_match(initial, level, config; game_id = 300 + g,
                                  p1_policy = :sector_gross, p2_policy = :random, p1_epsilon = 1, p2_epsilon = 1)
        mF = run_custom_1v1_match(initial, level, config; game_id = 300 + g,
                                  p1_policy = :random, p2_policy = :sector_gross, p1_epsilon = 1, p2_epsilon = 1)
        sec_vs_rand[2g - 1] = mE.winner == 1 ? 1.0 : mE.winner == 0 ? 0.5 : 0.0
        sec_vs_rand[2g]     = mF.winner == 2 ? 1.0 : mF.winner == 0 ? 0.5 : 0.0
    end

    n_pegs = max(1, length(level.pegs))
    return Dict(
        "num_matches" => n_matches,
        "completion_red_cleared_rate" => count(m -> m.reason == "all_red_cleared", baseline_matches) / n_matches,
        "balls_exhausted_rate" => count(m -> m.reason == "balls_exhausted", baseline_matches) / n_matches,
        "mean_turns" => mean(m.turns for m in baseline_matches),
        "mean_winner_score" => mean(max(m.p1_score, m.p2_score) for m in baseline_matches),
        "mean_score_diff_ratio" => mean(abs(m.p1_score - m.p2_score) / max(1.0, m.p1_score + m.p2_score) for m in baseline_matches),
        "turn_red_hit_rate" => mean(isempty(m.red_hits_turn) ? 0.0 : mean(m.red_hits_turn) for m in baseline_matches),
        "mean_penalties_per_match" => mean(count(>(0.0), m.penalties_turn) for m in baseline_matches),
        "mean_shared_bucket_catches" => mean(m.shared_bucket_hits for m in baseline_matches),
        "campaign_peg_coverage_frac" => mean(m.ever_hit_pegs / n_pegs for m in baseline_matches),
        "p1_win_rate" => p1_win_rate,
        "first_player_balance" => first_player_balance,
        "mean_lead_changes" => isempty(lead_changes_list) ? 0.0 : mean(lead_changes_list),
        "comeback_win_rate" => isempty(is_comeback_win) ? 0.0 : mean(is_comeback_win),
        "drama_deficit_overcome" => isempty(comeback_deficits) ? 0.0 : mean(comeback_deficits),
        "suspense_efk" => isempty(suspense_list) ? 0.0 : mean(suspense_list),
        "surprise_efk" => isempty(surprise_list) ? 0.0 : mean(surprise_list),
        "skill_ladder" => Dict(
            "tactical_vs_sector_winrate" => mean(tac_vs_sec),
            "precise_vs_sloppy_winrate" => mean(sec_vs_sloppy),
            "sector_vs_random_winrate" => mean(sec_vs_rand),
        ),
    )
end

# ---------------------------------------------------------------------------
# 5. Composite Level Quality Index (LQI) Synthesis
# ---------------------------------------------------------------------------

function compute_composite_scores(geom::Dict, turn1::Dict, camp::Dict)
    # 1. Agency & Controllability Score (Pillar I)
    # Combines Macro-Route Mutual Information I_2(A; O_route), Normalized Controllability C_2,
    # Blahut-Arimoto Empowerment E_2, and Active Action-Space Utilization (1 - f_dead).
    info2 = turn1["info_by_sigma"]["2"]["route"]
    mi_norm = clamp(info2["MI"] / 4.2, 0.0, 1.0)
    ctrl_norm = clamp(info2["controllability"] / 0.80, 0.0, 1.0)
    emp_norm = clamp(info2["empowerment"] / 5.2, 0.0, 1.0)
    active_space = 1.0 - turn1["dead_angle_frac"]
    pillar1_agency = 0.35 * mi_norm + 0.25 * ctrl_norm + 0.20 * emp_norm + 0.20 * active_space

    # 2. Dynamical Skill Horizon & Basin Structure (Pillar II)
    # Combines Integrated Trajectory Agency (AUC of collision-indexed MI across k=1..15),
    # Deep Cascade Survival P(hits >= 10), Skill Horizon k_{1/2}, and Coherent Prefix Basin Coverage.
    auc_scored = clamp(turn1["skill_horizon"]["auc_scored_mi_bits"] / 60.0, 0.0, 1.0)
    deep_cascade = clamp(turn1["skill_horizon"]["scored_active_frac"][10] / 0.85, 0.0, 1.0)
    kh_scored = clamp(turn1["skill_horizon"]["k_half_scored"] / 15.0, 0.0, 1.0)
    aimable = clamp(turn1["aimable_basin_frac"] / 0.50, 0.0, 1.0)
    pillar2_dynamics = 0.40 * auc_scored + 0.25 * deep_cascade + 0.20 * kh_scored + 0.15 * aimable

    # 3. Single-Turn Tactical Richness (Pillar III)
    # Combines Effective Competitive Sectors (Perplexity), First-Contact Reachability Breadth,
    # Style-Shot Affordance Salience, and Peg Exposure Equity (1 - Gini) scaled by board depth.
    sec_score = clamp(turn1["effective_competitive_sectors"] / 18.0, 0.0, 1.0)
    first_hit_breadth = clamp(turn1["distinct_first_hit_pegs"] / 40.0, 0.0, 1.0)
    style_salience = clamp(turn1["any_style_shot_rate"] / 0.35, 0.0, 1.0)
    board_scale = clamp(geom["total_pegs"] / 80.0, 0.0, 1.0)
    gini_equity = clamp(1.0 - turn1["peg_hit_gini"], 0.0, 1.0) * board_scale
    pillar3_tactics = 0.30 * sec_score + 0.25 * first_hit_breadth + 0.25 * style_salience + 0.20 * gini_equity

    # 4. 1v1 Competitive Drama, Pacing, Balance & Skill Gradient (Pillar IV)
    # Match pacing sweet spot: ~9-13 turns (5-7 shots per player) with high red-clearance completion.
    turns = camp["mean_turns"]
    pacing_score = turns < 2.0 ? 0.0 : clamp(1.0 - abs(turns - 10.5) / 9.5, 0.0, 1.0)
    comp_score = camp["completion_red_cleared_rate"]
    fairness = camp["first_player_balance"]
    drama_score = clamp(0.4 * (camp["mean_lead_changes"] / 1.5) +
                        0.3 * (camp["comeback_win_rate"] / 0.60) +
                        0.3 * (camp["suspense_efk"] / 0.18), 0.0, 1.0)
    skill_grad = clamp(0.5 * ((camp["skill_ladder"]["precise_vs_sloppy_winrate"] - 0.5) / 0.40) +
                       0.5 * ((camp["skill_ladder"]["sector_vs_random_winrate"] - 0.5) / 0.50), 0.0, 1.0)
    has_reds_gate = geom["red_pegs"] > 0 ? 1.0 : 0.05
    pillar4_1v1 = has_reds_gate * (0.25 * pacing_score + 0.15 * comp_score + 0.20 * fairness + 0.20 * drama_score + 0.20 * skill_grad)

    # 5. Structural Elegance & Behavioral Efficiency (Pillar V)
    # Combines Waveguide-to-Scatterer Balance 4*f_slide*(1-f_slide), 2D Spatial Entropy, and MDL Efficiency.
    wg_bal = geom["waveguide_scatterer_balance"]
    spatial_ent = geom["spatial_2d_entropy_norm"]
    mdl_eff = clamp((turn1["skill_horizon"]["auc_scored_mi_bits"] / log2(1.0 + geom["k_mdl_params"])) / 8.5, 0.0, 1.0)
    pillar5_elegance = 0.45 * wg_bal + 0.25 * spatial_ent + 0.30 * mdl_eff

    # Overall Level Quality Index (LQI) — geometric-arithmetic hybrid
    arith = 0.22 * pillar1_agency + 0.23 * pillar2_dynamics + 0.20 * pillar3_tactics + 0.23 * pillar4_1v1 + 0.12 * pillar5_elegance
    geom_mean = (max(0.01, pillar1_agency)^0.22 *
                 max(0.01, pillar2_dynamics)^0.23 *
                 max(0.01, pillar3_tactics)^0.20 *
                 max(0.01, pillar4_1v1)^0.23 *
                 max(0.01, pillar5_elegance)^0.12)
    lqi = 0.5 * arith + 0.5 * geom_mean

    return Dict(
        "Pillar1_Agency_Controllability" => pillar1_agency,
        "Pillar2_Dynamical_Skill_Horizon" => pillar2_dynamics,
        "Pillar3_Tactical_Landscape" => pillar3_tactics,
        "Pillar4_1v1_Competitive_Drama" => pillar4_1v1,
        "Pillar5_Structural_Elegance" => pillar5_elegance,
        "Overall_LQI" => lqi,
    )
end

function profile_level(level_path::String, config_path::String; cached_campaigns::Union{Nothing,Dict} = nothing)
    t0 = time()
    level = PeggleSim.load_level(level_path)
    config = PeggleSim.load_config(config_path)
    println("Profiling level: $(level.name) ($(level_path)) ...")

    geom = compute_static_geometry_metrics(level)
    records = run_single_turn_sweep(level, config)
    turn1 = analyze_single_turn(level, config, records)
    camp = if cached_campaigns !== nothing && haskey(cached_campaigns, level.name)
        cached_campaigns[level.name]
    else
        analyze_1v1_campaigns(level, config; n_matches = 8)
    end
    scores = compute_composite_scores(geom, turn1, camp)
    elapsed = time() - t0
    println(@sprintf("  Done in %.2f s -> LQI = %.3f (P1=%.2f, P2=%.2f, P3=%.2f, P4=%.2f, P5=%.2f)",
        elapsed, scores["Overall_LQI"],
        scores["Pillar1_Agency_Controllability"],
        scores["Pillar2_Dynamical_Skill_Horizon"],
        scores["Pillar3_Tactical_Landscape"],
        scores["Pillar4_1v1_Competitive_Drama"],
        scores["Pillar5_Structural_Elegance"]))

    return Dict(
        "level_name" => level.name,
        "level_path" => level_path,
        "config_path" => config_path,
        "elapsed_seconds" => elapsed,
        "static_geometry" => geom,
        "single_turn" => turn1,
        "campaign_1v1" => camp,
        "composite_scores" => scores,
    )
end

function main()
    reuse = "--reuse-campaigns" in ARGS
    out_path = "results/analysis/level_evaluation_profiles.json"
    cached_camps = Dict{String, Any}()
    if reuse && isfile(out_path)
        prev = JSON.parsefile(out_path)
        for (k, v) in prev
            if haskey(v, "campaign_1v1")
                cached_camps[k] = v["campaign_1v1"]
            end
        end
    end

    workloads = [
        ("fixtures/ribbon_waves/artifact/ribbon_waves.v1.json", "campaigns/ribbon/config.v1.json"),
        ("fixtures/mustache/artifact/mustache.v1.json", "fixtures/mustache/config.dev.v1.json"),
        ("interchange/levels/circle_level.v1.json", "campaigns/ribbon/config.v1.json"),
        ("interchange/levels/squiggly_circle.v1.json", "campaigns/ribbon/config.v1.json"),
        ("interchange/levels/slide.v1.json", "campaigns/ribbon/config.v1.json"),
    ]
    results = Dict{String, Any}()
    for (lpath, cpath) in workloads
        prof = profile_level(lpath, cpath; cached_campaigns = reuse ? cached_camps : nothing)
        results[prof["level_name"]] = prof
    end
    mkpath("results/analysis")
    open(out_path, "w") do io
        JSON.print(io, results, 2)
    end
    println("Saved complete profiles to $out_path")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
