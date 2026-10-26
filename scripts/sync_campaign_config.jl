#!/usr/bin/env julia
"""Export the current Lua config into campaign inputs, preserving golden fixtures."""

using JSON
using SHA

const ROOT = abspath(dirname(@__DIR__))
const PROG = "sync_campaign_config.jl"

struct CliError <: Exception
    msg::String
end

struct HelpRequested <: Exception end

function usage_text()
    return """
usage: $PROG [-h] [--lua-root LUA_ROOT] [--out-dir OUT_DIR]
                               [--check]

Export the current Lua config into campaign inputs, preserving golden
fixtures.

options:
  -h, --help           show this help message and exit
  --lua-root LUA_ROOT
  --out-dir OUT_DIR
  --check              check the saved export against the Lua source
"""
end

function parse_args(args::Vector{String})
    lua_root = joinpath(ROOT, "..", "peggle_evolved")
    out_dir = joinpath(ROOT, "campaigns", "ribbon")
    check = false
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "-h" || arg == "--help"
            throw(HelpRequested())
        elseif arg == "--lua-root" || arg == "--out-dir"
            i < length(args) || throw(CliError("argument $arg: expected one argument"))
            if arg == "--lua-root"
                lua_root = args[i + 1]
            else
                out_dir = args[i + 1]
            end
            i += 2
        elseif startswith(arg, "--lua-root=")
            lua_root = arg[length("--lua-root=")+1:end]
            i += 1
        elseif startswith(arg, "--out-dir=")
            out_dir = arg[length("--out-dir=")+1:end]
            i += 1
        elseif arg == "--check"
            check = true
            i += 1
        else
            throw(CliError("unrecognized arguments: $arg"))
        end
    end
    return (lua_root = lua_root, out_dir = out_dir, check = check)
end

function _sha256_bytes(data::AbstractVector{UInt8})
    return bytes2hex(sha256(data))
end

# Python `old.get(k) != v` comparison semantics for JSON values.  In
# particular Python considers True/False equal to 1/0.
function _json_equal(a, b)::Bool
    if a isa Bool && b isa Number
        return (a ? 1 : 0) == b
    elseif a isa Number && b isa Bool
        return a == (b ? 1 : 0)
    elseif a isa Number && b isa Number
        return a == b
    elseif a isa AbstractDict && b isa AbstractDict
        length(a) == length(b) || return false
        for (key, value) in a
            haskey(b, key) || return false
            _json_equal(value, b[key]) || return false
        end
        return true
    elseif a isa AbstractVector && b isa AbstractVector
        length(a) == length(b) || return false
        return all(_json_equal(x, y) for (x, y) in zip(a, b))
    else
        return a == b
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

    lua_root = abspath(options.lua_root)
    out_dir = abspath(options.out_dir)

    source = read(joinpath(lua_root, "src", "config.lua"))
    game_source = read(joinpath(lua_root, "src", "states", "game.lua"))
    source_sha = _sha256_bytes(source)

    export_tool = joinpath(ROOT, "tools", "export_config.lua")
    cmd = Cmd(Cmd(String["luajit", export_tool, "--reference", lua_root, "--source-sha256", source_sha]);
              dir = ROOT)
    export_buffer = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd), stdout = export_buffer))
    if !success(proc)
        error("luajit tools/export_config.lua failed with exit code $(proc.exitcode)")
    end
    export_bytes = take!(export_buffer)
    # `String(::Vector{UInt8})` takes ownership and empties the vector, so
    # parse a copy to retain the exact bytes for writing/comparison.
    config = JSON.parse(String(copy(export_bytes)))

    fixture = JSON.parse(read(joinpath(ROOT, "fixtures", "ribbon_waves", "config.dev.v1.json"), String))
    old = get(fixture, "values", Dict{String,Any}())

    changes = Dict{String,Any}()
    values = get(config, "values", Dict{String,Any}())
    for key in sort(collect(keys(values)))
        old_value = get(old, key, nothing)
        if !_json_equal(old_value, values[key])
            changes[key] = Dict{String,Any}("previous" => old_value, "current" => values[key])
        end
    end

    if options.check
        check_path = joinpath(out_dir, "config.v1.json")
        check_source_path = joinpath(out_dir, "config.source.lua")
        check_game_path = joinpath(out_dir, "game.source.lua")
        if !isfile(check_path) || read(check_path) != export_bytes
            error("campaign export differs from current Lua config")
        end
        if !isfile(check_source_path) || read(check_source_path) != source
            error("saved Lua source differs")
        end
        if !isfile(check_game_path) || read(check_game_path) != game_source
            error("saved match rules differ")
        end
        println("Campaign config matches current Lua source: $source_sha")
        return 0
    end

    mkpath(out_dir)
    write(joinpath(out_dir, "config.v1.json"), export_bytes)
    write(joinpath(out_dir, "config.source.lua"), source)
    write(joinpath(out_dir, "game.source.lua"), game_source)

    lua_revision = strip(read(Cmd(String["git", "-C", lua_root, "rev-parse", "HEAD"]), String))
    lua_config_dirty_raw = read(Cmd(String["git", "-C", lua_root, "status", "--porcelain", "--", "src/config.lua"]), String)
    metadata = Dict{String,Any}(
        "source" => "../peggle_evolved/src/config.lua",
        "source_sha256" => source_sha,
        "game_source_sha256" => _sha256_bytes(game_source),
        "lua_revision" => lua_revision,
        "lua_config_dirty" => !isempty(strip(lua_config_dirty_raw)),
        "changes_from_ribbon_fixture" => changes,
    )
    metadata_json = JSON.json(metadata, 2)
    write(joinpath(out_dir, "provenance.json"), metadata_json * "\n")
    println(metadata_json)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
