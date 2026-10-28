using Test
using PeggleSim
using PeggleSim.DetMath
import JSON

const DETMATH_PROJECT = normpath(joinpath(@__DIR__, ".."))

# Run a Julia subprocess in the pinned package environment with a controlled
# PEGGLE_MATH_BACKEND / PEGGLE_MATH_LIB environment. The parent process copy is
# inherited except for those two variables, so ambient settings cannot leak in.
function _run_detmath_subprocess(code::AbstractString;
                                 backend::Union{Nothing,String} = nothing,
                                 lib::Union{Nothing,String} = nothing)
    cmd = `$(Base.julia_cmd()) --project=$(DETMATH_PROJECT) -e $(code)`
    env = Pair{String,String}[]
    for (k, v) in ENV
        k == "PEGGLE_MATH_BACKEND" && continue
        k == "PEGGLE_MATH_LIB" && continue
        push!(env, String(k) => String(v))
    end
    backend === nothing || push!(env, "PEGGLE_MATH_BACKEND" => backend)
    lib === nothing || push!(env, "PEGGLE_MATH_LIB" => lib)
    cmd = setenv(cmd, env)
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
    return (
        success = success(proc),
        stdout = String(take!(out)),
        stderr = String(take!(err)),
    )
end

# Every DetMath function through one subprocess backend: one line of bit
# patterns, compared against the same probe computed in-process.
const DETMATH_PROBE_CODE = """
using PeggleSim
using PeggleSim.DetMath
values = (det_sin(1.0), det_cos(1.0), det_tan(0.5), det_asin(0.5),
          det_acos(0.5), det_atan(1.0), det_atan2(1.0, -1.0),
          det_exp(1.5), det_log(2.0), det_pow(2.0, -0.5), det_sqrt(2.0))
print(join(float_bits_hex.(values), " "))
"""

function _detmath_probe_line(f)
    values = (f.sin(1.0), f.cos(1.0), f.tan(0.5), f.asin(0.5), f.acos(0.5),
              f.atan(1.0), f.atan2(1.0, -1.0), f.exp(1.5), f.log(2.0),
              f.pow(2.0, -0.5), f.sqrt(2.0))
    return join(float_bits_hex.(values), " ")
end

const LIBM_PROBE = (
    sin = x -> ccall((:sin, "libm.so.6"), Float64, (Float64,), x),
    cos = x -> ccall((:cos, "libm.so.6"), Float64, (Float64,), x),
    tan = x -> ccall((:tan, "libm.so.6"), Float64, (Float64,), x),
    asin = x -> ccall((:asin, "libm.so.6"), Float64, (Float64,), x),
    acos = x -> ccall((:acos, "libm.so.6"), Float64, (Float64,), x),
    atan = x -> ccall((:atan, "libm.so.6"), Float64, (Float64,), x),
    atan2 = (y, x) ->
        ccall((:atan2, "libm.so.6"), Float64, (Float64, Float64), y, x),
    exp = x -> ccall((:exp, "libm.so.6"), Float64, (Float64,), x),
    log = x -> ccall((:log, "libm.so.6"), Float64, (Float64,), x),
    pow = (a, b) ->
        ccall((:pow, "libm.so.6"), Float64, (Float64, Float64), a, b),
    sqrt = x -> ccall((:sqrt, "libm.so.6"), Float64, (Float64,), x),
)

const BASE_PROBE = (
    sin = Base.sin, cos = Base.cos, tan = Base.tan, asin = Base.asin,
    acos = Base.acos, atan = Base.atan, atan2 = (y, x) -> Base.atan(y, x),
    exp = Base.exp, log = Base.log, pow = (a, b) -> Base.:^(a, b),
    sqrt = Base.sqrt,
)

const CORE_MATH_PROBE_CODE = """
using PeggleSim
using PeggleSim.DetMath
import JSON
id = math_backend_identity()
data = Dict{String,Any}(
    "backend" => String(id.backend),
    "library" => String(id.library),
    "platform" => String(id.platform),
    "abi_version" => id.abi_version,
    "artifact_sha256" => String(id.artifact_sha256),
    "core_math_revision" => String(id.core_math_revision),
    "core_math_tag" => String(id.core_math_tag),
    "sin1" => float_bits_hex(det_sin(1.0)),
    "sqrt4" => float_bits_hex(det_sqrt(4.0)),
)
print(JSON.json(data))
"""

@testset "DetMath" begin
    id = DetMath.math_backend_identity()
    @test id.backend isa Symbol
    @test id.julia == string(VERSION)
    @test id.library isa String
    @test id.platform isa String
    @test id.backend in (:system_libm, :core_math, :julia_base)
    @test MATH_BACKEND[] === id.backend
    if id.backend === :system_libm
        @test id.library == "libm.so.6"
        @test id.glibc isa String
        @test occursin(r"^\d+\.\d+", id.glibc)
        @test id.abi_version === nothing
        @test id.artifact_sha256 === nothing
    elseif id.backend === :julia_base
        @test id.library == Base.Math.libm
        @test id.glibc === nothing
        @test id.abi_version === nothing
        @test id.artifact_sha256 === nothing
    else
        @test isfile(id.library)
        @test id.abi_version == 1
        @test occursin(r"^[0-9a-f]{64}$", id.artifact_sha256)
        @test occursin(r"^[0-9a-f]{40}$", id.core_math_revision)
    end

    @testset "lua_mod sign and zero cases" begin
        # Expected values captured from LuaJIT 2.1 (`a % b`) and from the
        # frozen formula a - floor(a/b)*b.
        cases = [
            (-7.0, 3.0, 2.0),
            (7.0, 3.0, 1.0),
            (-7.0, -3.0, -1.0),
            (7.0, -3.0, -2.0),
            (0.0, 5.0, 0.0),
            (-0.0, 5.0, 0.0),
            (0.0, -5.0, 0.0),
            (-0.0, -5.0, 0.0),
            (5.5, 2.0, 1.5),
            (-5.5, 2.0, 0.5),
            (5.5, -2.0, -0.5),
            (-5.5, -2.0, -1.5),
            (1e-300, 1e-300, 0.0),
            (-1e-300, 1e-300, 0.0),
            (1e300, 3.0, 0.0),
            (-1e300, 3.0, 0.0),
        ]
        for (a, b, want) in cases
            got = lua_mod(a, b)
            @test got == want
            if want == 0.0
                @test !signbit(got)
            end
        end
        @test isnan(lua_mod(3.0, 0.0))
        @test isnan(lua_mod(-3.0, 0.0))
        @test isnan(lua_mod(0.0, 0.0))
    end

    @testset "core_math artifact filename" begin
        @test DetMath.core_math_artifact_filename("windows-x86_64") ==
              "peggle_math.dll"
        @test DetMath.core_math_artifact_filename("windows-aarch64") ==
              "peggle_math.dll"
        @test DetMath.core_math_artifact_filename("darwin-aarch64") ==
              "libpeggle_math.dylib"
        @test DetMath.core_math_artifact_filename("darwin-x86_64") ==
              "libpeggle_math.dylib"
        @test DetMath.core_math_artifact_filename("linux-x86_64") ==
              "libpeggle_math.so"
        @test DetMath.core_math_artifact_filename("freebsd-x86_64") ==
              "libpeggle_math.so"

        platform = DetMath._platform_name()
        default = DetMath._default_core_math_path()
        @test basename(default) ==
              DetMath.core_math_artifact_filename(platform)
        @test occursin(joinpath("native", "artifacts", platform), default)
        package_dir = pkgdir(DetMath)
        @test dirname(default) ==
              joinpath(dirname(dirname(String(package_dir))), "native",
                       "artifacts", platform)
    end

    @testset "backend selection (subprocess)" begin
        default = _run_detmath_subprocess(
            "using PeggleSim; " *
            "print(PeggleSim.DetMath.math_backend_identity().backend)")
        @test default.success
        @test strip(default.stdout) ==
              (Sys.islinux() ? "system_libm" : "julia_base")

        alias = _run_detmath_subprocess(
            "using PeggleSim; " *
            "print(PeggleSim.DetMath.math_backend_identity().backend)";
            backend = "openlibm")
        @test alias.success
        @test strip(alias.stdout) == "julia_base"

        unknown = _run_detmath_subprocess("using PeggleSim"; backend = "bogus")
        @test !unknown.success
        @test occursin("PEGGLE_MATH_BACKEND", unknown.stderr)
        @test occursin("bogus", unknown.stderr)

        base = _run_detmath_subprocess(DETMATH_PROBE_CODE; backend = "julia_base")
        @test base.success
        @test strip(base.stdout) == _detmath_probe_line(BASE_PROBE)

        if Sys.islinux()
            libm = _run_detmath_subprocess(
                DETMATH_PROBE_CODE; backend = "system_libm")
            @test libm.success
            @test strip(libm.stdout) == _detmath_probe_line(LIBM_PROBE)
        end

        # Hard failure with no fallback: always runs, even without artifacts.
        missing_lib = _run_detmath_subprocess("using PeggleSim";
            backend = "core_math", lib = "/nonexistent-peggle-math.so")
        @test !missing_lib.success
        @test occursin("/nonexistent-peggle-math.so", missing_lib.stderr)
        @test occursin("core_math", missing_lib.stderr)

        # The success-path test skips when the pinned artifact is absent.
        artifact = DetMath._default_core_math_path()
        if !isfile(artifact)
            @info "test_detmath: core_math artifact absent; skipping the " *
                  "core_math smoke test" artifact
            @test_skip true
        else
            core = _run_detmath_subprocess(
                CORE_MATH_PROBE_CODE; backend = "core_math")
            @test core.success
            data = JSON.parse(core.stdout)
            @test data["backend"] == "core_math"
            @test data["library"] == artifact
            @test data["platform"] == DetMath._platform_name()
            @test data["abi_version"] == 1
            @test data["artifact_sha256"] == sha256_hex(read(artifact))
            build = JSON.parsefile(joinpath(dirname(artifact), "build.json"))
            @test data["core_math_revision"] ==
                  String(build["core_math"]["revision"])
            @test data["sin1"] == "0x3feaed548f090cee"
            @test data["sqrt4"] == "0x4000000000000000"
        end
    end


end
