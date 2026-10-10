#!/usr/bin/env julia
# WP-D1: cross-backend summary for the math comparison.
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/wpd_summary.jl \
#       --dir tmp/core-math [--out tmp/core-math/math-summary.json]
#
# Reads the WP-D1 inputs, the two Lua result files, and the two comparison
# files; writes `math-summary.json` with:
#   * per-backend comparison summaries (counts, engine, oracle, special);
#   * the number of cases where the two backends' Lua bits differ, per
#     function and overall, plus the first differing case;
#   * SHA-256 of every generated artifact.
#
# The process exits nonzero when either comparator failed on an enforced
# check (engine, special, undecided, and for core_math also oracle
# correctness), when `oracle_undecided` is nonempty, or when the two backends
# produce identical bits everywhere (core_math did not engage).

using PeggleSim
import JSON

const DEFAULT_DIR = "tmp/core-math"
const GENERATED_FILES = [
    "wpd-inputs.json",
    "wpd-lua-system_libm.json",
    "wpd-lua-core_math.json",
    "wpd-compare-system_libm.json",
    "wpd-compare-core_math.json",
]

function parse_args(argv)
    opts = Dict{String,String}("dir" => DEFAULT_DIR)
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a in ("--dir", "--out")
            i += 1
            i <= length(argv) || error("missing value for $(a)")
            opts[a[3:end]] = argv[i]
        elseif a == "--help" || a == "-h"
            println("usage: wpd_summary.jl [--dir PATH] [--out PATH]")
            exit(0)
        else
            error("unknown argument: $(a)")
        end
        i += 1
    end
    haskey(opts, "out") || (opts["out"] = joinpath(opts["dir"], "math-summary.json"))
    return opts
end

function comparison_summary(doc)
    return Dict{String,Any}(
        "backend" => doc["backend"],
        "counts" => doc["counts"],
        "engine" => doc["engine"],
        "oracle" => doc["oracle"],
        "special" => doc["special"],
        "by_function" => doc["by_function"],
    )
end

function main(argv)
    opts = parse_args(argv)
    dir = opts["dir"]
    out_path = opts["out"]

    inputs_path = joinpath(dir, "wpd-inputs.json")
    lua_sys_path = joinpath(dir, "wpd-lua-system_libm.json")
    lua_core_path = joinpath(dir, "wpd-lua-core_math.json")
    cmp_sys_path = joinpath(dir, "wpd-compare-system_libm.json")
    cmp_core_path = joinpath(dir, "wpd-compare-core_math.json")

    inputs = JSON.parsefile(inputs_path)
    lua_sys = JSON.parsefile(lua_sys_path)
    lua_core = JSON.parsefile(lua_core_path)
    cmp_sys = JSON.parsefile(cmp_sys_path)
    cmp_core = JSON.parsefile(cmp_core_path)

    inputs["format"] == "peggle.wpd_math_inputs" ||
        error("unexpected inputs format: $(inputs["format"])")
    for (doc, backend) in ((lua_sys, "system_libm"), (lua_core, "core_math"))
        doc["format"] == "peggle.wpd_math_results" ||
            error("unexpected Lua results format: $(doc["format"])")
        String(doc["backend"]) == backend ||
            error("Lua results backend mismatch: $(doc["backend"]) != $(backend)")
    end
    for (doc, backend) in ((cmp_sys, "system_libm"), (cmp_core, "core_math"))
        doc["format"] == "peggle.wpd_math_comparison" ||
            error("unexpected comparison format: $(doc["format"])")
        String(doc["backend"]) == backend ||
            error("comparison backend mismatch: $(doc["backend"]) != $(backend)")
    end

    failures = String[]
    undecided_total = 0
    for (backend, doc) in (("system_libm", cmp_sys), ("core_math", cmp_core))
        engine = doc["engine"]
        oracle = doc["oracle"]
        special = doc["special"]
        Int(engine["mismatches"]) == 0 ||
            push!(failures, "$(backend): engine mismatches $(engine["mismatches"])")
        Int(special["mismatches"]) == 0 ||
            push!(failures, "$(backend): special mismatches $(special["mismatches"])")
        Int(oracle["undecided"]) == 0 ||
            push!(failures, "$(backend): oracle undecided $(oracle["undecided"])")
        undecided_total += Int(oracle["undecided"])
        if backend == "core_math" && Int(oracle["mismatches"]) != 0
            push!(failures, "core_math: oracle mismatches $(oracle["mismatches"])")
        end
    end

    undecided_inputs = 0
    for (_, idx) in inputs["oracle_undecided"]
        undecided_inputs += length(idx)
    end
    undecided_inputs == 0 ||
        push!(failures, "inputs oracle_undecided has $(undecided_inputs) entries")

    function_names = sort!(collect(keys(inputs["cases"])))
    diff_by_function = Dict{String,Any}()
    diff_total = 0
    first_difference = nothing
    for fn in function_names
        sys_results = lua_sys["results"][fn]
        core_results = lua_core["results"][fn]
        length(sys_results) == length(core_results) ||
            error("backend result arrays differ in length for $(fn)")
        n = 0
        section = inputs["cases"][fn]
        arity = Int(section["arity"])
        for i in eachindex(sys_results)
            if String(sys_results[i]) != String(core_results[i])
                n += 1
                diff_total += 1
                if first_difference === nothing
                    first_difference = Dict{String,Any}(
                        "function" => fn,
                        "index" => i,
                        "a" => String(section["a"][i]),
                        "b" => arity == 2 ? String(section["b"][i]) : nothing,
                        "system_libm" => String(sys_results[i]),
                        "core_math" => String(core_results[i]),
                    )
                end
            end
        end
        diff_by_function[fn] = n
    end
    diff_total > 0 || push!(failures,
        "no case differs between system_libm and core_math; core_math not engaged")

    files = Dict{String,Any}()
    for name in GENERATED_FILES
        path = joinpath(dir, name)
        files[name] = sha256_hex(read(path))
    end

    summary = Dict{String,Any}(
        "format" => "peggle.wpd_math_summary",
        "schema_version" => 1,
        "backends" => Dict{String,Any}(
            "system_libm" => comparison_summary(cmp_sys),
            "core_math" => comparison_summary(cmp_core),
        ),
        "cross_backend" => Dict{String,Any}(
            "differing_cases" => diff_total,
            "by_function" => diff_by_function,
            "first_difference" => first_difference,
        ),
        "files" => files,
        "failures" => failures,
        "ok" => isempty(failures),
    )

    out_dir = dirname(out_path)
    isempty(out_dir) || mkpath(out_dir)
    open(out_path, "w") do io
        write(io, canonical_json(summary))
        write(io, "\n")
    end

    println("wpd_summary: out=", out_path)
    for (backend, doc) in (("system_libm", cmp_sys), ("core_math", cmp_core))
        e = doc["engine"]
        o = doc["oracle"]
        s = doc["special"]
        println("  ", rpad(backend, 11),
                " cases=", e["checked"],
                " engine_mismatches=", e["mismatches"],
                " oracle_mismatches=", o["mismatches"],
                " oracle_enforced=", o["enforced"],
                " special_mismatches=", s["mismatches"],
                " undecided=", o["undecided"],
                " nan_sign_mismatches=", o["nan_sign_mismatches"])
    end
    println("  backends differ on ", diff_total, " cases:")
    for fn in function_names
        n = diff_by_function[fn]
        n == 0 || println("    ", rpad(fn, 6), " ", n)
    end
    if first_difference !== nothing
        println("  first difference: ", first_difference)
    end
    if !isempty(failures)
        for f in failures
            println("  FAILURE: ", f)
        end
        exit(1)
    end
    println("wpd_summary: OK")
    return nothing
end

main(ARGS)
