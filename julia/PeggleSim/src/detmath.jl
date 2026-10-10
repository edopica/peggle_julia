# Deterministic math backend for the Peggle Evolved port.
#
# The Lua reference (LuaJIT + LÖVE 11.5) evaluates the authoritative
# transcendental functions with the host C library. This module routes every
# authoritative call site through one explicitly selected backend:
#
#   :system_libm -- `ccall` into libm.so.6; the historical backend and the
#                   default on Linux (the same C library LuaJIT used on the
#                   reference host).
#   :core_math   -- the pinned shared native component (`peggle_math`, ABI 1)
#                   loaded from `native/artifacts/<platform>/libpeggle_math.so`
#                   or `ENV["PEGGLE_MATH_LIB"]`. Experimental; WP-F adoption
#                   is pending.
#   :julia_base  -- Julia runtime Base math (`Base.sin`, ...). This is NOT a
#                   claim about a pinned implementation: it is whatever math
#                   the running Julia runtime provides (the bundled openlibm
#                   on typical builds). The `openlibm` value is accepted as a
#                   backward-compatible alias but is always reported as
#                   `:julia_base`.
#
# The backend is chosen once, at module initialization, from
# `PEGGLE_MATH_BACKEND`. An unset or empty variable selects `:system_libm` on
# Linux and `:julia_base` elsewhere; unknown values throw at load. The
# environment is read in `__init__` only, never during precompilation, so one
# precompiled image serves every backend.
#
# `:core_math` resolves its library in this order:
#
#   1. `ENV["PEGGLE_MATH_LIB"]` when non-empty (absolute path recommended);
#   2. `<repo_root>/native/artifacts/<platform>/libpeggle_math.so`, where
#      `repo_root` is the repository containing this package and `<platform>`
#      is `linux-x86_64`, `darwin-aarch64`, or `windows-x86_64` (built from
#      `Sys.islinux`/`Sys.isapple`/`Sys.iswindows` and `Sys.ARCH`).
#
# A missing library, a missing symbol, or an ABI version other than 1 is an
# explicit startup error. There is no fallback to another backend.
#
# The deterministic path must stay strict IEEE: no fast-math annotations, no
# SIMD reductions, no fused multiply-add.
module DetMath

using JSON
using SHA
import Libdl

export MATH_BACKEND, math_backend_identity, lua_mod
export det_sin, det_cos, det_atan, det_atan2, det_asin, det_acos, det_tan,
       det_exp, det_log, det_pow, det_sqrt

const SYSTEM_LIBM = "libm.so.6"

const CORE_MATH_ABI_VERSION = 1
const CORE_MATH_DEFAULT_FILENAME = "libpeggle_math.so"

# Populated by __init__ from PEGGLE_MATH_BACKEND. The initial value is only a
# placeholder for the precompiled image; __init__ always runs before any
# exported function is usable.
const MATH_BACKEND = Ref{Symbol}(:system_libm)

# :core_math state. Every pointer stays C_NULL until _init_core_math! succeeds.
const CORE_MATH_HANDLE = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_LIBRARY = Ref{String}("")
const CORE_MATH_PLATFORM = Ref{String}("")
const CORE_MATH_ARTIFACT_SHA256 = Ref{String}("")
const CORE_MATH_REVISION = Ref{String}("")
const CORE_MATH_TAG = Ref{String}("")

const CORE_MATH_SIN = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_COS = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_TAN = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_ASIN = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_ACOS = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_ATAN = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_ATAN2 = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_EXP = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_LOG = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_POW = Ref{Ptr{Cvoid}}(C_NULL)
const CORE_MATH_SQRT = Ref{Ptr{Cvoid}}(C_NULL)

# ---------------------------------------------------------------------------
# Backend selection
# ---------------------------------------------------------------------------

function _selected_backend()::Symbol
    raw = get(ENV, "PEGGLE_MATH_BACKEND", "")
    if isempty(raw)
        return Sys.islinux() ? :system_libm : :julia_base
    elseif raw == "system_libm"
        return :system_libm
    elseif raw == "core_math"
        return :core_math
    elseif raw == "julia_base" || raw == "openlibm"
        return :julia_base
    else
        error("DetMath: unknown PEGGLE_MATH_BACKEND=\"$(raw)\"; expected " *
              "\"system_libm\", \"core_math\", or \"julia_base\" (alias " *
              "\"openlibm\")")
    end
end

# Platform tag used for the default artifact lookup and identity reporting.
function _platform_name()::String
    arch = string(Sys.ARCH)
    if Sys.islinux()
        return "linux-" * arch
    elseif Sys.isapple()
        return "darwin-" * arch
    elseif Sys.iswindows()
        return "windows-" * arch
    else
        return lowercase(string(Sys.KERNEL)) * "-" * arch
    end
end

function _default_core_math_path()::String
    package_dir = pkgdir(@__MODULE__)
    package_dir === nothing &&
        error("DetMath: cannot derive the package location for the core_math " *
              "artifact lookup; set PEGGLE_MATH_LIB explicitly")
    repo_root = dirname(dirname(String(package_dir)))
    return joinpath(repo_root, "native", "artifacts", _platform_name(),
                    CORE_MATH_DEFAULT_FILENAME)
end

function _resolve_core_math_path()::String
    override = get(ENV, "PEGGLE_MATH_LIB", "")
    isempty(override) || return abspath(override)
    return _default_core_math_path()
end

function _dlsym_required(handle::Ptr{Cvoid}, symbol::Symbol,
                         library::AbstractString)::Ptr{Cvoid}
    ptr = Libdl.dlsym(handle, symbol, throw_error = false)
    ptr === nothing &&
        error("DetMath: core_math library $(library) does not export " *
              ":$(symbol); rebuild the pinned component with " *
              "`make core-math-build`")
    return ptr
end

function _init_core_math!()
    path = _resolve_core_math_path()
    isfile(path) ||
        error("DetMath: PEGGLE_MATH_BACKEND=core_math but the native " *
              "component is missing at $(path); build it with " *
              "`make core-math-build` or set PEGGLE_MATH_LIB to the artifact " *
              "path. No fallback backend is used.")
    handle = try
        Libdl.dlopen(path)
    catch err
        error("DetMath: PEGGLE_MATH_BACKEND=core_math failed to load " *
              "$(path): $(sprint(showerror, err)). No fallback backend is used.")
    end

    abi_fn = _dlsym_required(handle, :peggle_math_abi_version, path)
    abi = ccall(abi_fn, Cint, ())
    abi == CORE_MATH_ABI_VERSION ||
        error("DetMath: $(path) reports peggle_math ABI version $(abi), but " *
              "this package requires $(CORE_MATH_ABI_VERSION); rebuild the " *
              "pinned component. No fallback backend is used.")

    identity_fn = _dlsym_required(handle, :peggle_math_identity, path)
    identity = try
        JSON.parse(unsafe_string(ccall(identity_fn, Cstring, ())))
    catch err
        error("DetMath: $(path) returned an unreadable " *
              "peggle_math_identity(): $(sprint(showerror, err))")
    end

    CORE_MATH_SIN[] = _dlsym_required(handle, :peggle_math_sin, path)
    CORE_MATH_COS[] = _dlsym_required(handle, :peggle_math_cos, path)
    CORE_MATH_TAN[] = _dlsym_required(handle, :peggle_math_tan, path)
    CORE_MATH_ASIN[] = _dlsym_required(handle, :peggle_math_asin, path)
    CORE_MATH_ACOS[] = _dlsym_required(handle, :peggle_math_acos, path)
    CORE_MATH_ATAN[] = _dlsym_required(handle, :peggle_math_atan, path)
    CORE_MATH_ATAN2[] = _dlsym_required(handle, :peggle_math_atan2, path)
    CORE_MATH_EXP[] = _dlsym_required(handle, :peggle_math_exp, path)
    CORE_MATH_LOG[] = _dlsym_required(handle, :peggle_math_log, path)
    CORE_MATH_POW[] = _dlsym_required(handle, :peggle_math_pow, path)
    CORE_MATH_SQRT[] = _dlsym_required(handle, :peggle_math_sqrt, path)

    CORE_MATH_HANDLE[] = handle
    CORE_MATH_LIBRARY[] = path
    CORE_MATH_PLATFORM[] = String(get(identity, "platform", _platform_name()))
    CORE_MATH_ARTIFACT_SHA256[] = bytes2hex(SHA.sha256(read(path)))
    CORE_MATH_REVISION[] = String(get(identity, "core_math_revision", ""))
    CORE_MATH_TAG[] = String(get(identity, "core_math_tag", ""))
    return nothing
end

function __init__()
    backend = _selected_backend()
    backend === :core_math && _init_core_math!()
    MATH_BACKEND[] = backend
    return nothing
end

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

function _glibc_version()
    try
        return unsafe_string(ccall(:gnu_get_libc_version, Cstring, ()))
    catch
        return nothing
    end
end

function math_backend_identity()
    backend = MATH_BACKEND[]
    if backend === :core_math
        return (
            backend = :core_math,
            library = CORE_MATH_LIBRARY[],
            platform = CORE_MATH_PLATFORM[],
            abi_version = CORE_MATH_ABI_VERSION,
            artifact_sha256 = CORE_MATH_ARTIFACT_SHA256[],
            core_math_revision = CORE_MATH_REVISION[],
            core_math_tag = CORE_MATH_TAG[],
            glibc = nothing,
            julia = string(VERSION),
        )
    elseif backend === :system_libm
        return (
            backend = :system_libm,
            library = SYSTEM_LIBM,
            platform = _platform_name(),
            abi_version = nothing,
            artifact_sha256 = nothing,
            core_math_revision = nothing,
            core_math_tag = nothing,
            glibc = _glibc_version(),
            julia = string(VERSION),
        )
    else
        return (
            backend = :julia_base,
            library = Base.Math.libm,
            platform = _platform_name(),
            abi_version = nothing,
            artifact_sha256 = nothing,
            core_math_revision = nothing,
            core_math_tag = nothing,
            glibc = nothing,
            julia = string(VERSION),
        )
    end
end

# JSON-ready view of math_backend_identity(); inapplicable fields are omitted
# so manifests stay free of null placeholders.
function math_backend_identity_dict()::Dict{String,Any}
    id = math_backend_identity()
    d = Dict{String,Any}(
        "backend" => String(id.backend),
        "library" => String(id.library),
        "platform" => String(id.platform),
        "julia" => String(id.julia),
    )
    id.abi_version === nothing || (d["abi_version"] = Int(id.abi_version))
    id.artifact_sha256 === nothing ||
        (d["artifact_sha256"] = String(id.artifact_sha256))
    id.core_math_revision === nothing ||
        (d["core_math_revision"] = String(id.core_math_revision))
    id.core_math_tag === nothing ||
        (d["core_math_tag"] = String(id.core_math_tag))
    id.glibc === nothing || (d["glibc"] = String(id.glibc))
    return d
end

# ---------------------------------------------------------------------------
# Authoritative functions
# ---------------------------------------------------------------------------

@noinline _unknown_backend(backend::Symbol) =
    error("DetMath: internal error: unknown backend $(backend)")

@inline function det_sin(x::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:sin, SYSTEM_LIBM), Float64, (Float64,), x)
    backend === :core_math &&
        return ccall(CORE_MATH_SIN[], Float64, (Float64,), x)
    backend === :julia_base && return Base.sin(x)
    return _unknown_backend(backend)
end

@inline function det_cos(x::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:cos, SYSTEM_LIBM), Float64, (Float64,), x)
    backend === :core_math &&
        return ccall(CORE_MATH_COS[], Float64, (Float64,), x)
    backend === :julia_base && return Base.cos(x)
    return _unknown_backend(backend)
end

@inline function det_tan(x::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:tan, SYSTEM_LIBM), Float64, (Float64,), x)
    backend === :core_math &&
        return ccall(CORE_MATH_TAN[], Float64, (Float64,), x)
    backend === :julia_base && return Base.tan(x)
    return _unknown_backend(backend)
end

@inline function det_asin(x::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:asin, SYSTEM_LIBM), Float64, (Float64,), x)
    backend === :core_math &&
        return ccall(CORE_MATH_ASIN[], Float64, (Float64,), x)
    backend === :julia_base && return Base.asin(x)
    return _unknown_backend(backend)
end

@inline function det_acos(x::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:acos, SYSTEM_LIBM), Float64, (Float64,), x)
    backend === :core_math &&
        return ccall(CORE_MATH_ACOS[], Float64, (Float64,), x)
    backend === :julia_base && return Base.acos(x)
    return _unknown_backend(backend)
end

@inline function det_atan(x::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:atan, SYSTEM_LIBM), Float64, (Float64,), x)
    backend === :core_math &&
        return ccall(CORE_MATH_ATAN[], Float64, (Float64,), x)
    backend === :julia_base && return Base.atan(x)
    return _unknown_backend(backend)
end

@inline function det_atan2(y::Float64, x::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:atan2, SYSTEM_LIBM), Float64, (Float64, Float64), y, x)
    backend === :core_math &&
        return ccall(CORE_MATH_ATAN2[], Float64, (Float64, Float64), y, x)
    backend === :julia_base && return Base.atan(y, x)
    return _unknown_backend(backend)
end

@inline function det_exp(x::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:exp, SYSTEM_LIBM), Float64, (Float64,), x)
    backend === :core_math &&
        return ccall(CORE_MATH_EXP[], Float64, (Float64,), x)
    backend === :julia_base && return Base.exp(x)
    return _unknown_backend(backend)
end

@inline function det_log(x::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:log, SYSTEM_LIBM), Float64, (Float64,), x)
    backend === :core_math &&
        return ccall(CORE_MATH_LOG[], Float64, (Float64,), x)
    backend === :julia_base && return Base.log(x)
    return _unknown_backend(backend)
end

@inline function det_pow(a::Float64, b::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:pow, SYSTEM_LIBM), Float64, (Float64, Float64), a, b)
    backend === :core_math &&
        return ccall(CORE_MATH_POW[], Float64, (Float64, Float64), a, b)
    backend === :julia_base && return Base.:^(a, b)
    return _unknown_backend(backend)
end

@inline function det_sqrt(x::Float64)::Float64
    backend = MATH_BACKEND[]
    backend === :system_libm &&
        return ccall((:sqrt, SYSTEM_LIBM), Float64, (Float64,), x)
    backend === :core_math &&
        return ccall(CORE_MATH_SQRT[], Float64, (Float64,), x)
    backend === :julia_base && return Base.sqrt(x)
    return _unknown_backend(backend)
end

# Lua's `%` operator is a floored modulo: a - floor(a/b)*b. C `fmod` and
# Julia `rem` truncate instead and must not be used on the authoritative path.
@inline lua_mod(a::Float64, b::Float64) = a - floor(a / b) * b

end # module DetMath
