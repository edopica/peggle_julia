#!/usr/bin/env julia
"""Run one benchmark process and record its wall time and peak RSS.

The M4 benchmark measures peak process memory per sweep.  The preferred
instrument is GNU ``time -v`` (``Maximum resident set size (kbytes)``), which
is what wiki/benchmarks/m3-shot.md style reports use.  Some hosts (including
the current Omarchy image) do not ship /usr/bin/time, so this wrapper falls
back to a small Python 3 standard-library helper that launches and waits for
the workload, then reads ``getrusage(RUSAGE_CHILDREN).ru_maxrss``. Reading
that counter in Julia includes memory inherited from the Julia launcher;
the helper excludes that footprint by spawning after Python has exec'd.
Peak RSS can still include the small helper footprint inherited at spawn.

Usage:
  julia --project=julia/PeggleSim scripts/bench_process.jl --out MEASUREMENT.json --label NAME -- COMMAND ...

The measurement JSON is canonical (sorted keys, one trailing newline).  The
wrapper forwards the child's stdout/stderr untouched and exits with the
child's exit status.
"""

using JSON

const GNU_TIME_DEFAULT = "/usr/bin/time"
const GNU_TIME_RSS_RE = r"Maximum resident set size \(kbytes\):\s*(\d+)"
const PROG = "bench_process.jl"

struct CliError <: Exception
    msg::String
end

struct HelpRequested <: Exception end

function usage_text()
    return """
usage: $PROG [-h] --out OUT [--label LABEL] [--time-bin TIME_BIN]
                        ...

Run a benchmark command and record wall time + peak RSS.

positional arguments:
  command              command to run (after --)

options:
  -h, --help           show this help message and exit
  --out OUT            measurement JSON output path
  --label LABEL        label recorded in the measurement JSON
  --time-bin TIME_BIN  GNU time binary (default: /usr/bin/time or \$GNU_TIME)
"""
end

function parse_args(args::Vector{String})
    out = nothing
    label = ""
    time_bin = get(ENV, "GNU_TIME", GNU_TIME_DEFAULT)
    command = String[]
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "-h" || arg == "--help"
            throw(HelpRequested())
        elseif arg == "--out" || arg == "--label" || arg == "--time-bin"
            i < length(args) || throw(CliError("argument $arg: expected one argument"))
            value = args[i + 1]
            if arg == "--out"
                out = value
            elseif arg == "--label"
                label = value
            else
                time_bin = value
            end
            i += 2
        elseif startswith(arg, "--out=")
            out = arg[length("--out=")+1:end]
            i += 1
        elseif startswith(arg, "--label=")
            label = arg[length("--label=")+1:end]
            i += 1
        elseif startswith(arg, "--time-bin=")
            time_bin = arg[length("--time-bin=")+1:end]
            i += 1
        elseif arg == "--"
            command = args[i+1:end]
            break
        elseif startswith(arg, "-") && arg != "-"
            throw(CliError("unrecognized arguments: $arg"))
        else
            # argparse.REMAINDER: everything from the first positional on.
            command = args[i:end]
            break
        end
    end
    if out === nothing || isempty(out)
        throw(CliError("the following arguments are required: --out"))
    end
    return (out = out, label = label, time_bin = time_bin, command = command)
end

function _load_gnu_time_output(path::AbstractString)
    try
        return read(path, String)
    catch
        return ""
    end
end

_wall_seconds(value::Real) = round(Float64(value); digits = 6)

function _write_measurement(path::AbstractString, measurement::AbstractDict)
    open(path, "w") do io
        _write_json_sorted(io, measurement, 0)
        print(io, "\n")
    end
end

# Pretty JSON with recursively sorted keys, matching json.dumps(indent=2,
# sort_keys=True) for the value shapes used here.
function _write_json_sorted(io::IO, value, depth::Int)
    if value isa AbstractDict
        keys_sorted = sort(collect(keys(value)); by = string)
        if isempty(keys_sorted)
            print(io, "{}")
            return
        end
        print(io, "{\n")
        for (index, key) in enumerate(keys_sorted)
            print(io, repeat("  ", depth + 1))
            print(io, JSON.json(string(key)))
            print(io, ": ")
            _write_json_sorted(io, value[key], depth + 1)
            index < length(keys_sorted) && print(io, ",")
            print(io, "\n")
        end
        print(io, repeat("  ", depth), "}")
    elseif value isa AbstractVector || value isa Tuple
        if isempty(value)
            print(io, "[]")
            return
        end
        print(io, "[\n")
        for (index, item) in enumerate(value)
            print(io, repeat("  ", depth + 1))
            _write_json_sorted(io, item, depth + 1)
            index < length(value) && print(io, ",")
            print(io, "\n")
        end
        print(io, repeat("  ", depth), "]")
    else
        print(io, JSON.json(value))
    end
end

function _spawn_error_text(exc)
    return "command not found: $(sprint(showerror, exc))"
end

# Julia stores signal termination separately from exitcode (which can be zero).
_process_exit_code(proc) = proc.termsignal == 0 ? Int(proc.exitcode) : 128 + Int(proc.termsignal)

function _run_and_measure(command::Vector{String})
    started = time_ns()
    try
        proc = run(ignorestatus(Cmd(command)))
        return (_process_exit_code(proc), (time_ns() - started) / 1e9, nothing)
    catch exc
        wall = (time_ns() - started) / 1e9
        return (127, wall, exc)
    end
end

function main(args::Vector{String} = ARGS)::Int
    options = try
        parse_args(args)
    catch exc
        if exc isa HelpRequested
            print(usage_text())
            return 0
        elseif exc isa CliError
            print(stderr, usage_text())
            println(stderr, "$PROG: error: $(exc.msg)")
            return 2
        else
            rethrow()
        end
    end

    command = String[options.command...]
    if !isempty(command) && command[1] == "--"
        command = command[2:end]
    end
    if isempty(command)
        println(stderr, "bench_process: ERROR: missing command after --")
        return 2
    end

    out_json = abspath(options.out)
    out_dir = dirname(out_json)
    if !isempty(out_dir)
        mkpath(out_dir)
    end

    time_bin = options.time_bin
    gnu_time = (!isempty(time_bin) && isfile(time_bin) && Sys.isexecutable(time_bin)) ? time_bin : nothing

    measurement = Dict{String,Any}(
        "label" => options.label,
        "command" => command,
    )
    started = time_ns()

    if gnu_time !== nothing
        time_output_path = out_json * ".gnu-time.txt"
        time_argv = String[gnu_time, "-v", "-o", time_output_path, "--"]
        append!(time_argv, command)
        exit_code = nothing
        spawn_exc = nothing
        try
            proc = run(ignorestatus(Cmd(time_argv)))
            exit_code = _process_exit_code(proc)
        catch exc
            spawn_exc = exc
        end
        wall = (time_ns() - started) / 1e9
        if spawn_exc !== nothing
            measurement["exit_code"] = 127
            measurement["wall_seconds"] = _wall_seconds(wall)
            measurement["peak_rss_kb"] = nothing
            measurement["peak_rss_mb"] = nothing
            measurement["method"] = "gnu_time_v"
            measurement["method_note"] = _spawn_error_text(spawn_exc)
            measurement["time_tool"] = gnu_time
            _write_measurement(out_json, measurement)
            return 127
        end
        text = _load_gnu_time_output(time_output_path)
        match_result = match(GNU_TIME_RSS_RE, text)
        peak_kb = match_result === nothing ? nothing : parse(Int, match_result.captures[1])
        measurement["exit_code"] = exit_code
        measurement["wall_seconds"] = _wall_seconds(wall)
        measurement["peak_rss_kb"] = peak_kb
        measurement["peak_rss_mb"] = peak_kb === nothing ? nothing : round(peak_kb / 1024.0; digits = 3)
        measurement["method"] = "gnu_time_v"
        measurement["method_note"] = "GNU time -v Maximum resident set size (kbytes) of the measured process tree"
        measurement["time_tool"] = gnu_time
        measurement["gnu_time_output"] = time_output_path
        _write_measurement(out_json, measurement)
        return exit_code
    end

    # Use a fresh small launcher: Julia's child accounting retains its large
    # inherited pre-exec footprint, even for a command such as /bin/true.
    exit_code, wall, peak_kb, error_note = mktemp() do path, io
        close(io)
        helper = joinpath(@__DIR__, "bench_process_resource.py")
        helper_command = vcat(String["python3", helper, path], command)
        code, elapsed, spawn_exc = _run_and_measure(helper_command)
        if spawn_exc !== nothing
            return (127, elapsed, nothing, _spawn_error_text(spawn_exc))
        end
        result = try
            JSON.parsefile(path)
        catch
            return (code == 0 ? 127 : code, elapsed, nothing,
                    "Python 3 resource helper failed to write a measurement (status $code)")
        end
        return (code, elapsed, result["peak_rss_kb"], get(result, "error", nothing))
    end
    measurement["exit_code"] = exit_code
    measurement["wall_seconds"] = _wall_seconds(wall)
    measurement["peak_rss_kb"] = peak_kb
    measurement["peak_rss_mb"] = peak_kb === nothing ? nothing : round(peak_kb / 1024.0; digits = 3)
    measurement["method"] = "python_resource_ru_maxrss"
    measurement["method_note"] = error_note === nothing ? "Python 3 helper getrusage(RUSAGE_CHILDREN).ru_maxrss after waiting for the measured child; excludes the Julia launcher footprint" : error_note
    measurement["time_tool"] = nothing
    _write_measurement(out_json, measurement)
    return exit_code
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
