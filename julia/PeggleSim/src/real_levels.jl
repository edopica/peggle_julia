# Registry of the six "real" levels.
#
# Tests, campaigns and benchmarks use only these boards. Five are the imported
# screenshot levels (fixtures/imported_levels); the sixth is ribbon_waves
# (fixtures/ribbon_waves). Both corpora are captured from the peggle_evolved
# dev tree, and their config artifacts are byte-identical to the campaign
# config (campaigns/ribbon/config.v1.json, RULES_RAMP_BUCKET).
#
# The module has no dependencies, so scripts that do not load PeggleSim (for
# example scripts/run_campaign_benchmark.jl) can `include` this file and use
# the same registry.
module RealLevels

const ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

"Names of the real levels, in a fixed order."
const NAMES = ("b1", "b2", "g1", "m1", "m2", "ribbon_waves")

"Default level for campaigns and benchmarks."
const DEFAULT = "ribbon_waves"

"Repository-relative path of the campaign config used with every real level."
const CONFIG = "campaigns/ribbon/config.v1.json"

is_real_level(name::AbstractString) = name in NAMES

function _check(name::AbstractString)
    is_real_level(name) || throw(ArgumentError(
        "unknown level $(repr(name)); real levels: $(join(NAMES, ", "))"))
    return String(name)
end

"Repository-relative directory of the fixture corpus that holds `name`."
corpus_dir(name::AbstractString) =
    _check(name) == "ribbon_waves" ? "fixtures/ribbon_waves" : "fixtures/imported_levels"

"Repository-relative path of the level artifact for `name`."
artifact_relpath(name::AbstractString) =
    corpus_dir(name) * "/artifact/" * String(name) * ".v1.json"

"Absolute path of the level artifact for `name`."
artifact_path(name::AbstractString) = joinpath(ROOT, artifact_relpath(name))

"Absolute path of the campaign config (shared by all real levels)."
config_path() = joinpath(ROOT, CONFIG)

"Absolute path of the captured config artifact stored with `name`'s corpus."
fixture_config_path(name::AbstractString) =
    joinpath(ROOT, corpus_dir(name), "config.dev.v1.json")

"""
    resolve(spec) -> Vector{Tuple{String,String}}

Resolve a `--level` value into `(label, absolute artifact path)` pairs.
`"all"` gives every real level, a real level name gives that level, and
anything else is treated as a path to a level artifact (relative paths
resolve against the current directory); its label is the file name without
`.v1.json`.
"""
function resolve(spec::AbstractString)
    spec == "all" && return [(n, artifact_path(n)) for n in NAMES]
    is_real_level(spec) && return [(String(spec), artifact_path(spec))]
    path = abspath(spec)
    label = replace(basename(path), r"(\.v1)?\.json$" => "")
    return [(label, path)]
end

end # module RealLevels
