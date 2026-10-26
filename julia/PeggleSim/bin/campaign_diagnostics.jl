#!/usr/bin/env julia
# Separate diagnostic process: never used by headline throughput runner.
const ENTRY_NS = time_ns()
const ENTRY_UNIX = time()
using PeggleSim, JSON, SHA, Profile

function rss_bytes()
    Sys.islinux() || return nothing
    for line in eachline("/proc/self/status")
        startswith(line, "VmRSS:") && return parse(Int, split(line)[2]) * 1024
    end
    return nothing
end

writejson(path, x) = open(io -> (JSON.print(io, x, 2); println(io)), path, "w")
gamehash(games) = bytes2hex(sha256(PeggleSim.canonical_json(games)))

# Leaf-first attribution: the deepest recognizable kernel owns the sample.
# These are exclusive stack categories, not source-line cycle measurements.
function category(frames)
    names = [string(f.func) for f in frames]
    any(n -> occursin(r"gc_collect|gc_mark|gc_sweep|sweep_pool|mark_loop|gc_try_claim", n), names) && return "gc"
    for f in frames
        n, file = string(f.func), basename(string(f.file))
        n in ("broad_phase_pass", "broad_phase_common") && return "broad_phase"
        file in ("physics.jl", "impact_geometry.jl") && return "precise_collision_and_physics"
        file in ("events.jl", "style_shots.jl") && return "scoring_and_events"
        n in ("score_peg!", "reduce_peg_contacts!", "get_turn_score", "get_turn_peg_score") && return "scoring_and_events"
        file in ("engine.jl", "ball_state.jl", "bucket.jl", "powers.jl", "fever_buckets.jl", "slide_inversion.jl") && return "engine_updates"
        file == "campaign.jl" && return "campaign_and_reset"
    end
    return "runtime_or_other"
end

function save_cpu(out)
    mkpath(out)
    data, dict = Profile.retrieve()
    # Portable text includes C frames and line attribution; addresses alone
    # would be meaningless after this process exits.
    open(joinpath(out, "cpu-tree.txt"), "w") do io
        Profile.print(io, data, dict; format=:tree, C=true, mincount=2, groupby=:thread)
    end
    counts = Dict{String,Int}()
    folded = Dict{String,Int}()
    frames = Base.StackTraces.StackFrame[]
    # The profile runs sequentially on thread 1 (-t N,0). Exclude parked
    # pool threads from category percentages; all-thread tree remains available.
    # Metadata layout helpers belong to the pinned Julia 1.12 Profile stdlib.
    selected = UInt[]
    first_ip = 1
    for i in eachindex(data)
        if Profile.is_block_end(data, i)
            if data[i - Profile.META_OFFSET_THREADID] == 1
                append!(selected, @view data[first_ip:i])
            end
            first_ip = i + 1
        end
    end
    for ip in Profile.strip_meta(selected)
        if ip == 0
            if !isempty(frames)
                key = category(frames)
                counts[key] = get(counts, key, 0) + 1
                stack = join(reverse(["$(f.func)@$(f.file):$(f.line)" for f in frames]), ';')
                folded[stack] = get(folded, stack, 0) + 1
                empty!(frames)
            end
        else
            append!(frames, get(dict, ip, Base.StackTraces.StackFrame[]))
        end
    end
    open(joinpath(out, "cpu-stacks.jsonl"), "w") do io
        for (stack, count) in sort(collect(folded); by=first)
            JSON.print(io, (; stack, count)); println(io)
        end
    end
    return (; samples_by_category=counts, samples=sum(values(counts)),
        buffer_full=Profile.is_buffer_full(), interval_seconds=0.01,
        attribution="exclusive deepest recognized stack category; primary campaign thread only; all-thread tree retained; physics includes integration/resolution; inlining and native GC limit attribution")
end

frame_label(f) = "$(f.func)@$(f.file):$(f.line)"

function save_allocations(out, rate)
    mkpath(out)
    counts = Dict{String,Int}()
    sizes = Dict{String,Int}()
    sites = Dict{String,Int}()
    samples = Profile.Allocs.fetch().allocs
    open(joinpath(out, "allocation-samples.jsonl"), "w") do io
        for a in samples
            frames = a.stacktrace
            cat = category(frames)
            counts[cat] = get(counts, cat, 0) + 1
            sizes[cat] = get(sizes, cat, 0) + a.size
            frame = findfirst(f -> occursin("PeggleSim/src/", string(f.file)), frames)
            site = frame === nothing ? "runtime_or_other" : frame_label(frames[frame])
            sites[site] = get(sites, site, 0) + a.size
            JSON.print(io, (; type=string(a.type), size_bytes=a.size,
                category=cat, stack=frame_label.(frames))); println(io)
        end
    end
    return (; sample_rate=rate, sampled_allocations=length(samples),
        sampled_bytes_by_category=sizes, sampled_counts_by_category=counts,
        sampled_bytes_by_site=sites,
        interpretation="random allocation-event samples; sampled bytes are not total bytes; do not interpret profiling wall time as throughput")
end

# Exact historical boundary: setup/simulation, equality verification, JSON write/close.
function trial(level, config, o, enabled, expected, path)
    start = time_ns()
    run = PeggleSim.run_campaign(level, config, o; parallel=o.workers>1,
        phase_instrumentation=enabled)
    simulation_end = time_ns()
    identical = expected === nothing || run.games == expected
    open(path, "w") do io
        JSON.print(io, run, 2); println(io)
    end
    identical || error("gameplay mismatch; differing history retained at $path")
    finish = time_ns()
    return (; run, wall_seconds=(finish-start)/1e9,
        campaign_setup_and_simulation_seconds=(simulation_end-start)/1e9,
        verification_and_output_seconds=(finish-simulation_end)/1e9)
end

function main(args)
    d = Dict("workers"=>"1", "games"=>"8", "repeats"=>"3", "kind"=>"timing",
        "out"=>"", "max-turns"=>"100", "max-steps"=>"3600", "allocation-rate"=>"0.01")
    iseven(length(args)) || error("options require values")
    for i in 1:2:length(args)
        k = replace(args[i], "--"=>"")
        haskey(d,k) || error("unknown option $(args[i])")
        d[k] = args[i+1]
    end
    d["kind"] in ("timing", "cpu", "allocations") || error("invalid kind")
    isempty(d["out"]) && error("--out required")
    out = abspath(d["out"])
    isdir(out) && error("output exists: $out")
    mkpath(out)
    n(k) = parse(Int,d[k])
    rate = parse(Float64,d["allocation-rate"])
    0 < rate <= 1 || error("allocation-rate must be in (0,1]")
    o = PeggleSim.CampaignOptions(games=n("games"), workers=n("workers"),
        max_turns=n("max-turns"), max_steps=n("max-steps"))
    PeggleSim.validate_campaign(o)
    o.workers <= o.games && o.workers <= Threads.nthreads() || error("invalid worker/thread count")
    n("repeats") > 0 || error("repeats must be positive")
    d["kind"] == "timing" || o.workers == 1 || error("profiles initially require one worker")
    entry_to_load = (time_ns()-ENTRY_NS)/1e9
    t = time_ns()
    loaded = @timed (PeggleSim.load_level("fixtures/ribbon_waves/artifact/ribbon_waves.v1.json"),
        PeggleSim.load_config("campaigns/ribbon/config.v1.json"))
    level, config = loaded.value
    load_seconds = (time_ns()-t)/1e9
    loaded_rss = rss_bytes()
    trials = Any[]
    report = Dict{String,Any}("schema_version"=>"campaign-diagnostics/1", "protocol_version"=>"campaign-diagnostics/1",
        "kind"=>d["kind"], "options"=>d, "loaded_rss_bytes"=>loaded_rss,
        "load_compile_seconds"=>loaded.compile_time, "load_recompile_seconds"=>loaded.recompile_time,
        "entry_to_load_seconds"=>entry_to_load, "entry_unix_seconds"=>ENTRY_UNIX, "load_seconds"=>load_seconds,
        "runtime"=>Dict("julia"=>string(VERSION), "default_threads"=>Threads.nthreads(:default),
            "interactive_threads"=>Threads.nthreads(:interactive), "gc_threads"=>Threads.ngcthreads(),
            "cpu_target"=>get(ENV,"JULIA_CPU_TARGET","runtime default"), "math_backend"=>string(PeggleSim.DetMath.MATH_BACKEND[])),
        "trials"=>trials)
    write(joinpath(out,"stage.txt"), "warmup")
    # Tested variants warmed only at this process's worker setting, including
    # equality, output and instrumentation wrappers. Warmup can include compilation.
    warm_start = time_ns()
    expected = nothing
    warmup_measurements = Any[]
    for enabled in (d["kind"] == "timing" ? (true, false) : (false,))
        timed = @timed trial(level,config,o,enabled,expected,joinpath(out,"warmup-$enabled.json"))
        expected === nothing && (expected = timed.value.run.games)
        push!(warmup_measurements, Dict("phase_instrumentation"=>enabled,
            "wall_seconds"=>timed.value.wall_seconds, "compile_seconds"=>timed.compile_time,
            "recompile_seconds"=>timed.recompile_time, "allocated_bytes"=>timed.bytes,
            "gc_seconds"=>timed.gctime, "gc_collections"=>timed.gcstats.pause))
    end
    report["warmup_seconds"] = (time_ns()-warm_start)/1e9
    report["warmup_measurements"] = warmup_measurements
    report["warmup_compile_seconds"] = sum(w["compile_seconds"] for w in warmup_measurements)
    report["warmed_rss_bytes"] = rss_bytes()
    report["warmup_gameplay_sha256"] = gamehash(expected)
    writejson(joinpath(out,"report.json"),report)
    println("Warmed $(d["kind"]) workers=$(o.workers)"); flush(stdout)
    for rep in 1:n("repeats")
        variants = d["kind"] == "timing" ? (isodd(rep) ? (true,false) : (false,true)) : (false,)
        for enabled in variants
            GC.gc()
            d["kind"] == "cpu" && (Profile.init(n=10^7,delay=0.01); Profile.clear())
            d["kind"] == "allocations" && Profile.Allocs.clear()
            path = joinpath(out,"history-r$rep-$enabled.json")
            write(joinpath(out,"stage.txt"), "campaign-r$rep-$enabled")
            timed = if d["kind"] == "cpu"
                @timed Profile.@profile trial(level,config,o,enabled,expected,path)
            elseif d["kind"] == "allocations"
                @timed Profile.Allocs.@profile sample_rate=rate trial(level,config,o,enabled,expected,path)
            else
                @timed trial(level,config,o,enabled,expected,path)
            end
            post_rss = rss_bytes()
            write(joinpath(out,"stage.txt"), "post-campaign")
            v = timed.value
            # Hashing and profile decoding happen outside the measured boundary.
            row = Dict{String,Any}("repeat"=>rep,"phase_instrumentation"=>enabled,
                "wall_seconds"=>v.wall_seconds,
                "campaign_setup_and_simulation_seconds"=>v.campaign_setup_and_simulation_seconds,
                "verification_and_output_seconds"=>v.verification_and_output_seconds,
                "allocated_bytes"=>timed.bytes,"gc_collections"=>timed.gcstats.pause,
                "gc_full_collections"=>timed.gcstats.full_sweep,"gc_seconds"=>timed.gctime,
                "compile_seconds"=>timed.compile_time,"recompile_seconds"=>timed.recompile_time,
                "post_campaign_rss_bytes"=>post_rss,"process_lifetime_peak_rss_bytes"=>Sys.maxrss(),
                "completed_matches"=>count(g->g["completed"],v.run.games),
                "candidates"=>sum(t.candidates for t in v.run.timings),
                "gameplay_sha256"=>gamehash(v.run.games),"history"=>basename(path))
            d["kind"] == "cpu" && (row["cpu"] = save_cpu(joinpath(out,"profile-r$rep")))
            d["kind"] == "allocations" && (row["allocations"] = save_allocations(joinpath(out,"profile-r$rep"),rate))
            push!(trials,row)
            writejson(joinpath(out,"report.json"),report)
            println("$(d["kind"]) workers=$(o.workers) repeat=$rep phases=$enabled wall=$(round(v.wall_seconds;digits=3))s"); flush(stdout)
        end
    end
end
main(ARGS)
