#!/usr/bin/env julia
# Emit a cross-machine parity manifest (WP-F).
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/parity_emit.jl \
#       [--label local] [--repo .] [--out results/parity/local.json]
#
# The process exits nonzero when the math census does not verify exactly or
# when reset determinism fails.

using PeggleSim

function parse_args(argv)
    opts = Dict{String,String}("label" => "local")
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in ("--label", "--repo", "--out")
            i += 1
            i <= length(argv) || error("missing value for $(arg)")
            opts[arg[3:end]] = argv[i]
        elseif arg == "--help" || arg == "-h"
            println("usage: parity_emit.jl [--label LABEL] [--repo PATH] [--out PATH]")
            exit(0)
        else
            error("unknown argument: $(arg)")
        end
        i += 1
    end
    return opts
end

function main(argv)
    opts = parse_args(argv)
    repo = get(opts, "repo", pwd())
    label = get(opts, "label", "local")
    out = get(opts, "out", joinpath(repo, "results", "parity", label * ".json"))

    man = PeggleSim.parity_manifest(; repo = repo, label = label)
    PeggleSim.write_parity(man, out)

    auth = PeggleSim.parity_authoritative(man)
    verified = auth["math_census"]["verified"] === true
    deterministic = auth["reset_deterministic"] === true
    rng_verified = auth["rng_sequences"]["verified"] === true
    colors_verified = auth["peg_colors"]["verified"] === true
    restored = all(cfg -> cfg["restored_matches_original"] === true,
                   values(auth["reset"]))

    println("parity manifest: ", out)
    println("  label=", label,
            " reference_revision=", man["identity"]["reference_revision"])
    println("  math_census_verified=", verified,
            " total_cases=", auth["math_census"]["total_cases"],
            " mismatches=", auth["math_census"]["mismatches"])
    println("  rng_verified=", rng_verified,
            " checked=", auth["rng_sequences"]["checked"],
            " mismatches=", auth["rng_sequences"]["mismatches"])
    println("  peg_colors_verified=", colors_verified,
            " checked=", auth["peg_colors"]["checked"],
            " mismatches=", auth["peg_colors"]["mismatches"])
    println("  reset_deterministic=", deterministic,
            " restored_matches_original=", restored,
            " configurations=", length(auth["reset"]))

    if !verified
        println("  ERROR: math census verification failed")
        exit(1)
    end
    if !rng_verified
        println("  ERROR: RNG fixture verification failed")
        exit(1)
    end
    if !colors_verified
        println("  ERROR: peg-color fixture verification failed")
        exit(1)
    end
    if !deterministic || !restored
        println("  ERROR: reset determinism failed")
        exit(1)
    end
    return nothing
end

main(ARGS)
