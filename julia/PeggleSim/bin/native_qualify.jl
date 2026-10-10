#!/usr/bin/env julia
# Runtime qualification smoke for the selected DetMath math backend.
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/native_qualify.jl \
#       [--backend core_math] [--lib PATH]
#
# --backend/--lib are applied to the process environment BEFORE `using
# PeggleSim`, because DetMath selects its backend once, in `__init__`.
# --backend defaults to core_math; without the override the script requires
# that core_math really loaded. --lib sets PEGGLE_MATH_LIB (default lookup:
# native/artifacts/<platform>/<artifact>).
#
# The script verifies the loaded backend identity (backend, platform, ABI,
# CORE-MATH revision, resolved library, artifact sha256), then evaluates the
# 11 authoritative functions plus the package's floored-mod equivalent on a
# fixed input table and requires exact IEEE-754 bit patterns, including the
# WP-D hard acos case where glibc is one ULP off. Exit status is nonzero on
# any failed check. This is the per-host runtime qualification for a
# cross-built native artifact.
#
# Example:
#   PEGGLE_MATH_LIB=native/artifacts/linux-x86_64/libpeggle_math.so \
#     julia --project=julia/PeggleSim julia/PeggleSim/bin/native_qualify.jl

function parse_args(argv)
    opts = Dict{String,String}()
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in ("--backend", "--lib")
            i += 1
            i <= length(argv) || error("missing value for $(arg)")
            opts[arg[3:end]] = argv[i]
        elseif arg == "--help" || arg == "-h"
            println("usage: native_qualify.jl [--backend NAME] [--lib PATH]")
            println()
            println("--backend  DetMath backend to qualify (default core_math:")
            println("           system_libm, core_math, julia_base/openlibm)")
            println("--lib      PEGGLE_MATH_LIB override (absolute path recommended)")
            exit(0)
        else
            error("unknown argument: $(arg)")
        end
        i += 1
    end
    return opts
end

# Must run before `using PeggleSim`: DetMath reads PEGGLE_MATH_BACKEND and
# PEGGLE_MATH_LIB in its `__init__`.
const OPTS = parse_args(ARGS)
ENV["PEGGLE_MATH_BACKEND"] = get(OPTS, "backend", "core_math")
haskey(OPTS, "lib") && (ENV["PEGGLE_MATH_LIB"] = OPTS["lib"])

using PeggleSim
using PeggleSim.DetMath

# Fixed input table: (label, call, expected IEEE-754 bit pattern). Expected
# values are CORE-MATH (correctly rounded) outputs. The acos hard case is the
# documented WP-D first non-NaN backend difference: glibc returns
# 0x3fab00d4161ed823 where CORE-MATH returns 0x3fab00d4161ed824.
const CHECKS = (
    ("sin(0.0)", () -> det_sin(0.0), 0x0000000000000000),
    ("sin(-0.0)", () -> det_sin(-0.0), 0x8000000000000000),
    ("cos(0.0)", () -> det_cos(0.0), 0x3ff0000000000000),
    ("tan(0.0)", () -> det_tan(0.0), 0x0000000000000000),
    ("asin(0.0)", () -> det_asin(0.0), 0x0000000000000000),
    ("acos(1.0)", () -> det_acos(1.0), 0x0000000000000000),
    ("atan(0.0)", () -> det_atan(0.0), 0x0000000000000000),
    ("atan2(0.0,1.0)", () -> det_atan2(0.0, 1.0), 0x0000000000000000),
    ("exp(0.0)", () -> det_exp(0.0), 0x3ff0000000000000),
    ("log(1.0)", () -> det_log(1.0), 0x0000000000000000),
    ("pow(2.0,10.0)", () -> det_pow(2.0, 10.0), 0x4090000000000000),
    ("sqrt(4.0)", () -> det_sqrt(4.0), 0x4000000000000000),
    ("sin(1.0)", () -> det_sin(1.0), 0x3feaed548f090cee),
    ("acos(0x3feff49bfa1a7806)",
        () -> det_acos(reinterpret(Float64, 0x3feff49bfa1a7806)),
        0x3fab00d4161ed824),
)

# The native component has no mod export; the package's DetMath.lua_mod is
# the authoritative floored modulo. Skip with a note if the package ever
# drops it instead of failing the whole qualification.
function mod_checks()
    isdefined(DetMath, :lua_mod) || return nothing
    return (
        ("mod(5.5,2.0)", () -> lua_mod(5.5, 2.0), 0x3ff8000000000000),
        ("mod(-1.0,3.0)", () -> lua_mod(-1.0, 3.0), 0x4000000000000000),
    )
end

function expected_backend(requested::AbstractString)::String
    return requested == "openlibm" ? "julia_base" : requested
end

function run_checks(checks)
    passed = 0
    for (label, call, want) in checks
        got = float_bits_hex(call())
        want_text = "0x" * string(want, base = 16, pad = 16)
        if got == want_text
            passed += 1
            println("PASS ", rpad(label, 24), " -> ", got)
        else
            println("FAIL ", rpad(label, 24), " -> ", got,
                    " expected ", want_text)
        end
    end
    return passed
end

function main(argv)
    requested = get(OPTS, "backend", "core_math")
    overridden = haskey(OPTS, "backend")
    expected = expected_backend(requested)

    id = DetMath.math_backend_identity()
    actual = String(id.backend)

    println("native_qualify: requested=", requested,
            " (", overridden ? "explicit" : "default", ")",
            " loaded=", actual)
    println("identity: ", canonical_json(DetMath.math_backend_identity_dict()))
    println("library: ", String(id.library))
    id.artifact_sha256 === nothing ||
        println("artifact_sha256: ", String(id.artifact_sha256))

    if actual != expected
        println("FAIL backend: loaded $(actual), requested $(expected)")
        return 1
    end
    if !overridden && actual != "core_math"
        println("FAIL backend: core_math is required unless --backend overrides it")
        return 1
    end
    if id.backend === :core_math
        if id.abi_version != DetMath.CORE_MATH_ABI_VERSION
            println("FAIL identity: ABI ", id.abi_version, ", expected ",
                    DetMath.CORE_MATH_ABI_VERSION)
            return 1
        end
        if isempty(String(id.core_math_revision))
            println("FAIL identity: empty core_math_revision")
            return 1
        end
        if isempty(String(id.platform))
            println("FAIL identity: empty platform")
            return 1
        end
    end

    checks = CHECKS
    extra = mod_checks()
    if extra === nothing
        println("NOTE DetMath.lua_mod not available; skipping the mod checks")
    else
        checks = (CHECKS..., extra...)
    end

    passed = run_checks(checks)
    total = length(checks)
    failed = total - passed
    if failed == 0
        println("native_qualify: PASS (", passed, "/", total,
                " checks; backend=", actual, ")")
        return 0
    end
    println("native_qualify: FAIL (", failed, "/", total,
            " checks failed; backend=", actual, ")")
    return 1
end

exit(main(ARGS))
