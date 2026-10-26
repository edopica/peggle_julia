# Benchmark index generation.
#
# Julia port of scripts/generate_benchmark_index.py. This file is included
# *inside* the BenchmarkHarness module (after schema.jl / harness.jl /
# validator.jl), so it declares no module and imports nothing.
#
# Responsibilities:
#   * scan runs_dir/*/manifest.json (sorted by path),
#   * reject duplicate run IDs, run-ID/directory mismatches, unreadable manifests,
#   * build one INDEX_CSV_COLUMNS row per run with root-relative manifest paths,
#   * sort rows by (timestamp_utc, run_id),
#   * atomically replace the index, keeping the previous file on any failure,
#   * optionally regenerate each run's README.md from its CSV tables.

# Return the manifest field `key`, treating JSON null like an absent value so
# that missing metadata becomes an empty CSV cell (the Python CSV writer does
# the same for None).
function _index_manifest_value(manifest::AbstractDict, key::AbstractString)
    value = get(manifest, key, "")
    return value === nothing ? "" : value
end

# Nested manifest sections (host, source, ...) default to an empty object.
function _index_manifest_dict(manifest::AbstractDict, key::AbstractString)
    value = get(manifest, key, nothing)
    return value isa AbstractDict ? value : Dict{String,Any}()
end

# Canonicalize for relative-path computation; realpath mirrors Python's
# Path.resolve() but falls back to abspath for paths that do not exist.
function _index_absolute(path::AbstractString)
    try
        return realpath(path)
    catch
        return abspath(path)
    end
end

# Equivalent of Path.resolve().relative_to(root.resolve()): raise when the
# manifest lives outside the repository root rather than emitting "../".
function _index_relative_path(path::AbstractString, root_dir::AbstractString)
    absolute_path = _index_absolute(path)
    absolute_root = _index_absolute(root_dir)
    relative = relpath(absolute_path, absolute_root)
    separator = Base.Filesystem.path_separator
    if isabspath(relative) || relative == ".." || startswith(relative, ".." * separator)
        throw(ArgumentError(
            "Manifest path $(absolute_path) is not relative to root directory $(absolute_root)"
        ))
    end
    return relative
end

# One index row, guaranteed to carry exactly the INDEX_CSV_COLUMNS keys.
function _index_row(fields::AbstractDict)
    return Dict{String,Any}(column => get(fields, column, "") for column in INDEX_CSV_COLUMNS)
end

"""
    generate_index(runs_dir, out_path, root_dir; update_readme=true) -> Vector{Dict{String,Any}}

Rebuild the benchmark index at `out_path` from `runs_dir/*/manifest.json`.

Rows are sorted by `(timestamp_utc, run_id)` and written with exactly
`INDEX_CSV_COLUMNS` values. The write goes through a temporary file in the
output directory followed by an atomic rename, so an existing index survives
any scanning, validation, or write failure. When `update_readme` is true each
run's `README.md` is regenerated from its `trials.csv` / `matches.csv` (missing
tables are treated as empty).

Returns the generated rows (also when the runs directory is missing, in which
case the old index is left untouched and a message is printed).
"""
function generate_index(
    runs_dir,
    out_path,
    root_dir;
    update_readme::Bool = true,
)::Vector{Dict{String,Any}}
    runs_dir_string = String(runs_dir)
    out_path_string = String(out_path)
    root_dir_string = String(root_dir)

    if !isdir(runs_dir_string)
        println("Runs directory does not exist: $(runs_dir_string)")
        return Dict{String,Any}[]
    end

    # Python: sorted(runs_dir.glob("*/manifest.json"))
    manifest_files = String[]
    for entry in readdir(runs_dir_string; join = true)
        isdir(entry) || continue
        candidate = joinpath(entry, "manifest.json")
        isfile(candidate) && push!(manifest_files, candidate)
    end
    sort!(manifest_files)

    index_rows = Dict{String,Any}[]
    seen_ids = Set{Any}()
    readmes = Tuple{String,String}[]

    for manifest_path in manifest_files
        run_dir = dirname(manifest_path)
        run_dir_name = basename(run_dir)

        manifest = try
            load_manifest(manifest_path)
        catch err
            throw(ArgumentError(
                "Could not read $(manifest_path): $(sprint(showerror, err))"
            ))
        end

        run_id = get(manifest, "run_id", run_dir_name)
        if run_id in seen_ids
            throw(ArgumentError("Duplicate run_id '$(run_id)' in $(manifest_path)"))
        end
        push!(seen_ids, run_id)
        if run_id != run_dir_name
            throw(ArgumentError(
                "Run ID '$(run_id)' does not match directory $(run_dir_name)"
            ))
        end

        host = _index_manifest_dict(manifest, "host")
        source = _index_manifest_dict(manifest, "source")

        row = _index_row(Dict{String,Any}(
            "run_id" => run_id,
            "benchmark" => _index_manifest_value(manifest, "benchmark"),
            "timestamp_utc" => _index_manifest_value(manifest, "timestamp_utc"),
            "host_id" => _index_manifest_value(host, "host_id"),
            "git_revision" => _index_manifest_value(source, "git_revision"),
            "workload_id" => _index_manifest_value(manifest, "workload_id"),
            "protocol_version" => _index_manifest_value(manifest, "protocol_version"),
            "schema_version" => _index_manifest_value(manifest, "schema_version"),
            "status" => _index_manifest_value(manifest, "status"),
            "manifest_path" => _index_relative_path(manifest_path, root_dir_string),
        ))
        push!(index_rows, row)

        if update_readme
            trials_path = joinpath(run_dir, "trials.csv")
            matches_path = joinpath(run_dir, "matches.csv")
            trials_rows = isfile(trials_path) ?
                read_csv_rows(trials_path).rows : Dict{String,String}[]
            matches_rows = isfile(matches_path) ?
                read_csv_rows(matches_path).rows : Dict{String,String}[]
            readme_text = generate_run_readme(manifest, trials_rows, matches_rows)
            push!(readmes, (joinpath(run_dir, "README.md"), readme_text))
        end
    end

    # Sort index by timestamp_utc ascending, then run_id (stable, like Python's
    # list.sort).
    sort!(
        index_rows;
        by = row -> (string(row["timestamp_utc"]), string(row["run_id"])),
        alg = MergeSort,
    )

    # Preserve the previous index if scanning or writing the replacement fails.
    mkpath(dirname(out_path_string))
    temporary_path = tempname(dirname(out_path_string); cleanup = false)
    try
        write_csv_rows(temporary_path, INDEX_CSV_COLUMNS, index_rows)
        # POSIX rename replaces atomically; Julia's mv() removes the target
        # first, which would briefly lose the old index.
        Base.Filesystem.rename(temporary_path, out_path_string)
    finally
        isfile(temporary_path) && rm(temporary_path; force = true)
    end

    for (readme_path, readme_text) in readmes
        write(readme_path, readme_text)
    end

    return index_rows
end
