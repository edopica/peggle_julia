# Benchmark schema, hashing, CSV, archive, manifest, and README helpers.
#
# Included inside BenchmarkHarness (see BenchmarkHarness.jl); this file must not
# declare a module or add `using` statements.  It is a faithful Julia port of
# the runner-facing subset of scripts/benchmark_schema.py.

const SCHEMA_VERSION::String = "1.0.0"
const PROTOCOL_VERSION::String = "1.0.0"

const MAX_SAFE_INTEGER = 9007199254740992  # 2^53

const HARNESS_DEFAULT_FILES::Vector{String} = [
    "campaigns/ribbon/config.source.lua",
    "campaigns/ribbon/game.source.lua",
    "julia/PeggleSim/Manifest.toml",
    "julia/PeggleSim/bin/campaign.jl",
    "julia/PeggleSim/src/campaign.jl",
    "scripts/sync_campaign_config.jl",
]

const INDEX_CSV_COLUMNS::Vector{String} = [
    "run_id",
    "benchmark",
    "timestamp_utc",
    "host_id",
    "git_revision",
    "workload_id",
    "protocol_version",
    "schema_version",
    "status",
    "manifest_path",
]

const TRIALS_CSV_COLUMNS::Vector{String} = [
    "run_id",
    "trial_id",
    "execution_order",
    "repeat_index",
    "mode",
    "workers",
    "wall_seconds",
    "campaign_setup_and_sim_seconds",
    "verification_and_output_seconds",
    "sim_phase_seconds",
    "candidate_reset_phase_seconds",
    "selection_phase_seconds",
    "actual_shot_phase_seconds",
    "checkpoint_phase_seconds",
    "completed_matches",
    "candidates",
    "candidates_per_second",
    "completed_matches_per_hour",
    "decision_mean_seconds",
    "decision_p50_seconds",
    "decision_p95_seconds",
    "process_rss_bytes",
    "process_peak_rss_bytes",
    "allocated_bytes",
    "gc_collections",
    "gc_seconds",
    "gameplay_sha256",
]

const MATCHES_CSV_COLUMNS::Vector{String} = [
    "run_id",
    "trial_id",
    "repeat_index",
    "workers",
    "match_id",
    "worker_index",
    "base_seed",
    "bot_seed_1",
    "bot_seed_2",
    "gameplay_seed",
    "turns",
    "candidates",
    "wall_seconds",
    "sim_phase_seconds",
    "termination_reason",
    "completed",
    "winner",
    "player1_score",
    "player2_score",
    "gameplay_sha256",
]

# ==============================================================================
# Small Python-semantics helpers
# ==============================================================================

_schema_py_str(v) = v === nothing || v === missing ? "None" :
                    v isa Bool ? (v ? "True" : "False") :
                    v isa AbstractString ? String(v) :
                    v isa Integer ? string(v) :
                    v isa AbstractFloat ? _schema_float_str(v) :
                    string(v)

function _schema_float_str(v::AbstractFloat)
    isnan(v) && return "nan"
    isinf(v) && return v > 0 ? "inf" : "-inf"
    return string(v)
end

function _schema_truthy(v)
    v === nothing && return false
    v === missing && return false
    v isa Bool && return v
    v isa AbstractString && return !isempty(v)
    v isa AbstractArray && return !isempty(v)
    v isa AbstractDict && return !isempty(v)
    v isa Number && return v != 0
    return true
end

function _schema_dict(v)
    v isa AbstractDict && return v
    return Dict{String,Any}()
end

function _schema_to_int(v)
    v isa Bool && return Int(v)
    v isa Integer && return Int(v)
    v isa AbstractFloat && return Int(trunc(v))
    v isa AbstractString && return parse(Int, strip(v))
    return Int(v)
end

function _schema_to_float(v)
    v isa AbstractString && return parse(Float64, strip(v))
    return Float64(v)
end

function _schema_to_bigint(v)
    # Python: int(float(value)) -- go through a double first, then truncate.
    f = v isa AbstractString ? parse(Float64, strip(v)) : Float64(v)
    return BigInt(trunc(f))
end

function _schema_require(row, key)
    haskey(row, key) || error("KeyError: $(key)")
    return row[key]
end

function _schema_row_get(row, key, default=nothing)
    return haskey(row, key) ? row[key] : default
end

# Python format(value, ".Nf"), with Python's inf/nan spelling.
function _schema_fixed(v, digits::Int)
    x = v isa AbstractString ? parse(Float64, strip(v)) : Float64(v)
    isnan(x) && return "nan"
    if isinf(x)
        return x > 0 ? "inf" : "-inf"
    end
    digits == 1 && return @sprintf("%.1f", x)
    digits == 2 && return @sprintf("%.2f", x)
    digits == 3 && return @sprintf("%.3f", x)
    digits == 4 && return @sprintf("%.4f", x)
    return @sprintf("%.17g", x)
end

_schema_f1(v) = _schema_fixed(v, 1)
_schema_f2(v) = _schema_fixed(v, 2)
_schema_f3(v) = _schema_fixed(v, 3)
_schema_f4(v) = _schema_fixed(v, 4)

function _schema_group_digits(digits::AbstractString)
    n = length(digits)
    n <= 3 && return String(digits)
    out = IOBuffer()
    first_group = n % 3
    first_group == 0 && (first_group = 3)
    write(out, digits[1:first_group])
    pos = first_group + 1
    while pos <= n
        write(out, ',')
        write(out, digits[pos:pos + 2])
        pos += 3
    end
    return String(take!(out))
end

# Python format(int(value), ",").
function _schema_grouped_int(n)
    s = string(n)
    if startswith(s, "-")
        return "-" * _schema_group_digits(s[2:end])
    end
    return _schema_group_digits(s)
end

# Python format(float(value), ",.Nf"): group the integer part only.
function _schema_grouped_float(v, digits::Int)
    s = _schema_fixed(v, digits)
    neg = startswith(s, "-")
    neg && (s = s[2:end])
    has_dot = occursin('.', s)
    intpart, fracpart = has_dot ? (split(s, '.'; limit=2)[1], split(s, '.'; limit=2)[2]) : (s, "")
    if !isempty(intpart) && all(isdigit, intpart)
        intpart = _schema_group_digits(intpart)
    end
    return (neg ? "-" : "") * intpart * (has_dot ? "." * fracpart : "")
end

_schema_grouped_f1(v) = _schema_grouped_float(v, 1)

# Python statistics.median for a non-empty iterable.
function _median(values)
    xs = Float64[]
    for v in values
        push!(xs, v isa AbstractString ? parse(Float64, strip(v)) : Float64(v))
    end
    isempty(xs) && error("median requires at least one value")
    sort!(xs)
    n = length(xs)
    if isodd(n)
        return xs[(n + 1) ÷ 2]
    end
    return (xs[n ÷ 2] + xs[n ÷ 2 + 1]) / 2.0
end

# ==============================================================================
# Canonical JSON & hashing
# ==============================================================================

sha256_bytes(data::AbstractVector{UInt8})::String =
    bytes2hex(SHA.sha256(Vector{UInt8}(data)))

sha256_bytes(data::AbstractString)::String =
    sha256_bytes(Vector{UInt8}(codeunits(data)))

function sha256_file(path)::String
    h = SHA.SHA256_CTX()
    open(String(path), "r") do io
        buf = Vector{UInt8}(undef, 65536)
        while !eof(io)
            n = readbytes!(io, buf, 65536)
            n == 0 && break
            SHA.update!(h, view(buf, 1:n))
        end
    end
    return bytes2hex(SHA.digest!(h))
end

function compute_harness_fingerprint(
    root_dir;
    files=nothing,
    precomputed_hashes=nothing,
)::Tuple{String,Dict{String,String}}
    file_list = files === nothing ? copy(HARNESS_DEFAULT_FILES) :
                String[String(f) for f in files]

    file_hashes = Dict{String,String}()
    manifest = IOBuffer()

    for rel_path in sort(file_list)
        h = ""
        if precomputed_hashes !== nothing && haskey(precomputed_hashes, rel_path)
            h = String(precomputed_hashes[rel_path])
        else
            full_path = joinpath(root_dir, rel_path)
            ispath(full_path) || error("Harness file not found: $(full_path)")
            h = sha256_file(full_path)
        end
        file_hashes[rel_path] = h
        write(manifest, h, "  ", rel_path, "\n")
    end

    fingerprint = sha256_bytes(String(take!(manifest)))
    return fingerprint, file_hashes
end

# ==============================================================================
# Canonical gameplay history & artifacts
# ==============================================================================

function save_canonical_gameplay_history(histories_dir, games)::Tuple{String,String}
    dir = String(histories_dir)
    mkpath(dir)
    c_json = canonical_json(games)
    c_bytes = Vector{UInt8}(codeunits(c_json))
    h = sha256_bytes(c_bytes)
    out_path = joinpath(dir, h * ".json")
    if !ispath(out_path)
        open(out_path, "w") do io
            write(io, c_bytes)
        end
    end
    return h, out_path
end

function _schema_copy_item(src::String, dest::String)
    parent = dirname(dest)
    isempty(parent) || mkpath(parent)
    if isdir(src)
        cp(src, dest; recursive=true, force=true)
    else
        cp(src, dest; force=true)
    end
    return nothing
end

function create_artifact_archive(archive_path, file_items)::Tuple{String,Int}
    archive = String(archive_path)
    parent = dirname(archive)
    isempty(parent) || mkpath(parent)
    archive = abspath(archive)

    items = Tuple{String,String}[]
    for item in file_items
        src, arcname = item
        push!(items, (String(src), String(arcname)))
    end
    # Deterministic ordering by archive member name (stable, like Python).
    sort!(items; by=item -> item[2], alg=MergeSort)

    staging = mktempdir()
    try
        members = String[]
        for (src, arcname) in items
            _schema_copy_item(src, joinpath(staging, arcname))
            push!(members, arcname)
        end

        # `-T` + newline-separated names is understood by GNU tar and bsdtar;
        # the harness arcnames never contain newlines or a leading dash.
        members_path = joinpath(staging, ".members")
        open(members_path, "w") do io
            for member in members
                write(io, member)
                write(io, '\n')
            end
        end

        run(`tar -czf $archive -C $staging -T $members_path`)
    finally
        rm(staging; recursive=true, force=true)
    end

    return sha256_file(archive), Int(filesize(archive))
end

function archive_member_bytes(archive_path, member)::Union{Nothing,Vector{UInt8}}
    out = IOBuffer()
    ok = false
    try
        ok = success(pipeline(
            `tar -xOzf $(String(archive_path)) -- $(String(member))`;
            stdout=out,
            stderr=devnull,
        ))
    catch
        return nothing
    end
    ok || return nothing
    return take!(out)
end

function archive_member_size(archive_path, member)::Union{Nothing,Int}
    data = archive_member_bytes(archive_path, member)
    data === nothing && return nothing
    return length(data)
end

# ==============================================================================
# CSV I/O
# ==============================================================================

struct CsvTable
    header::Vector{String}
    rows::Vector{Dict{String,String}}
end

function _parse_csv_text(text::String)::Vector{Vector{String}}
    data = codeunits(text)
    n = length(data)
    records = Vector{Vector{String}}()

    i = 1
    while i <= n
        fields = String[]
        field = UInt8[]
        in_quotes = false
        at_field_start = true
        had_content = false

        while i <= n
            b = data[i]
            if in_quotes
                if b == UInt8('"')
                    if i < n && data[i + 1] == UInt8('"')
                        push!(field, UInt8('"'))
                        i += 2
                    else
                        in_quotes = false
                        i += 1
                    end
                else
                    push!(field, b)
                    i += 1
                end
            elseif b == UInt8('"') && at_field_start
                in_quotes = true
                at_field_start = false
                had_content = true
                i += 1
            elseif b == UInt8(',')
                push!(fields, String(copy(field)))
                empty!(field)
                at_field_start = true
                had_content = true
                i += 1
            elseif b == UInt8('\n')
                i += 1
                break
            elseif b == UInt8('\r')
                i += (i < n && data[i + 1] == UInt8('\n')) ? 2 : 1
                break
            else
                push!(field, b)
                at_field_start = false
                had_content = true
                i += 1
            end
        end

        # Python's csv.reader yields an empty record for a blank line; keep it
        # so header selection matches DictReader (the first record is the
        # header even when it is blank).  Data rows skip empty records below.
        if had_content
            push!(fields, String(copy(field)))
        end
        push!(records, fields)
    end

    return records
end

function read_csv_rows(path)::CsvTable
    path_str = String(path)
    ispath(path_str) || error("CSV file not found: $(path_str)")
    text = read(path_str, String)
    records = _parse_csv_text(text)

    header = isempty(records) ? String[] : records[1]
    rows = Dict{String,String}[]

    for record in records[2:end]
        # csv.DictReader ignores blank rows in the data section.
        isempty(record) && continue
        row = Dict{String,String}()
        # Match csv.DictReader: fields missing from a short row stay absent
        # (Python maps them to None), and extra fields are ignored (Python
        # stores them under the None restkey).
        for idx in 1:min(length(header), length(record))
            row[header[idx]] = record[idx]
        end
        push!(rows, row)
    end

    return CsvTable(header, rows)
end

function _csv_cell(v)
    (v === nothing || v === missing) && return ""
    v isa Bool && return v ? "true" : "false"
    if v isa AbstractFloat
        isnan(v) && return "nan"
        isinf(v) && return v > 0 ? "inf" : "-inf"
        # Python writes integral floats as integers.
        return isinteger(v) ? string(BigInt(v)) : @sprintf("%.17g", v)
    end
    v isa Integer && return string(v)
    v isa AbstractString && return String(v)
    return string(v)
end

function _csv_quote(field::String)
    needs_quote = false
    for c in field
        if c == ',' || c == '"' || c == '\n' || c == '\r'
            needs_quote = true
            break
        end
    end
    needs_quote || return field
    return "\"" * replace(field, "\"" => "\"\"") * "\""
end

function write_csv_rows(path, fieldnames::Vector{String}, rows)
    path_str = String(path)
    parent = dirname(path_str)
    isempty(parent) || mkpath(parent)

    open(path_str, "w") do io
        write(io, join((_csv_quote(String(name)) for name in fieldnames), ","), "\n")
        for row in rows
            cells = String[]
            for name in fieldnames
                push!(cells, _csv_cell(_schema_row_get(row, name, nothing)))
            end
            if length(cells) == 1 && isempty(cells[1])
                # Python csv writes a sole empty field as a quoted empty field.
                write(io, "\"\"\n")
            else
                write(io, join((_csv_quote(cell) for cell in cells), ","), "\n")
            end
        end
    end
    return nothing
end

# ==============================================================================
# Manifest / checks JSON I/O
# ==============================================================================

function _schema_write_pretty_json(io, obj)
    buf = IOBuffer()
    JSON.print(buf, obj, 2)
    s = String(take!(buf))
    # JSON.print(..., 2) already ends with a newline; Python's json.dumps + "\n"
    # has exactly one.  Normalise instead of blindly appending a second one.
    while endswith(s, "\n")
        s = s[1:end - 1]
    end
    write(io, s, "\n")
    return nothing
end

function load_manifest(path)::Dict{String,Any}
    path_str = String(path)
    ispath(path_str) || error("Manifest not found: $(path_str)")
    data = JSON.parsefile(path_str)
    data isa AbstractDict || error("Manifest is not a JSON object: $(path_str)")
    return convert(Dict{String,Any}, data)
end

function save_manifest(path, manifest)
    path_str = String(path)
    parent = dirname(path_str)
    isempty(parent) || mkpath(parent)
    open(path_str, "w") do io
        _schema_write_pretty_json(io, manifest)
    end
    return nothing
end

function load_checks(path)::Dict{String,Any}
    path_str = String(path)
    ispath(path_str) || error("Checks file not found: $(path_str)")
    data = JSON.parsefile(path_str)
    data isa AbstractDict || error("Checks file is not a JSON object: $(path_str)")
    return convert(Dict{String,Any}, data)
end

function save_checks(path, checks)
    path_str = String(path)
    parent = dirname(path_str)
    isempty(parent) || mkpath(parent)
    open(path_str, "w") do io
        _schema_write_pretty_json(io, checks)
    end
    return nothing
end

# ==============================================================================
# README summary generator
# ==============================================================================

function generate_run_readme(manifest, trials_rows, matches_rows)::String
    run_id = _schema_py_str(_schema_row_get(manifest, "run_id", "unknown"))
    benchmark = _schema_py_str(_schema_row_get(manifest, "benchmark", "unknown"))
    workload_id = _schema_py_str(_schema_row_get(manifest, "workload_id", "unknown"))
    timestamp = _schema_py_str(_schema_row_get(manifest, "timestamp_utc", "unknown"))
    host = _schema_dict(_schema_row_get(manifest, "host", Dict{String,Any}()))
    runtime = _schema_dict(_schema_row_get(manifest, "runtime", Dict{String,Any}()))
    source = _schema_dict(_schema_row_get(manifest, "source", Dict{String,Any}()))
    workload = _schema_dict(_schema_row_get(manifest, "workload", Dict{String,Any}()))
    importer = _schema_row_get(manifest, "importer", nothing)

    # Aggregate worker scaling stats.
    worker_groups = Dict{Int,Vector{Any}}()
    for r in trials_rows
        w = _schema_to_int(_schema_require(r, "workers"))
        push!(get!(worker_groups, w, Any[]), r)
    end

    sorted_workers = sort(collect(keys(worker_groups)))
    repeat_indices = sort(unique(Int[_schema_to_int(_schema_require(r, "repeat_index"))
                                     for r in trials_rows]))

    repeat_header = "| Workers | " *
        join(("Repeat $(r) (s)" for r in repeat_indices), " | ") * " |"
    repeat_separator = "| ---: |" * (" ---: |"^length(repeat_indices))

    repeat_counts = unique(Int[length(rows) for rows in values(worker_groups)])
    repetitions = length(repeat_counts) == 1 ?
        "$(repeat_counts[1]) repetition(s) per worker count" :
        "the available repetitions per worker count"

    completion_summary = "completion status recorded below"
    if !isempty(matches_rows)
        all_completed = true
        for m in matches_rows
            completed = _schema_row_get(m, "completed", "")
            if lowercase(_schema_py_str(completed)) != "true"
                all_completed = false
                break
            end
        end
        all_completed && (completion_summary = "all completed")
    end

    function artifact_link(name)
        artifacts = _schema_dict(_schema_row_get(manifest, "artifacts", Dict{String,Any}()))
        item = _schema_dict(_schema_row_get(artifacts, name, Dict{String,Any}()))
        location = _schema_row_get(item, "uri", nothing)
        _schema_truthy(location) || (location = _schema_row_get(item, "path", nothing))
        _schema_truthy(location) || return "unavailable"
        location_str = _schema_py_str(location)
        target = if occursin("://", location_str) || startswith(location_str, "/")
            location_str
        else
            # Manifest artifact paths are repository-relative; README lives at
            # results/benchmarks/runs/<id>/README.md.
            relpath(location_str, "results/benchmarks/runs/$(run_id)")
        end
        return "[`$(location_str)`](<$(target)>)"
    end

    # Baseline wall time for worker 1.
    w1_wall_median = 0.0
    if haskey(worker_groups, 1)
        w1_wall_median = _median(_schema_to_float(_schema_require(r, "wall_seconds"))
                                 for r in worker_groups[1])
    end

    scaling_rows = String[]
    repeat_rows = String[]
    latency_rows = String[]
    phase_rows = String[]

    for w in sorted_workers
        rows = worker_groups[w]
        walls = Float64[_schema_to_float(_schema_require(r, "wall_seconds")) for r in rows]
        cands_sec = Float64[_schema_to_float(_schema_require(r, "candidates_per_second"))
                            for r in rows]
        matches_hr = Float64[_schema_to_float(_schema_require(r,
                                                               "completed_matches_per_hour"))
                             for r in rows]

        wall_med = _median(walls)
        cands_med = _median(cands_sec)
        matches_hr_med = _median(matches_hr)
        speedup = (wall_med > 0 && w1_wall_median > 0) ?
                  w1_wall_median / wall_med : nothing
        speedup_text = speedup === nothing ? "N/A" : _schema_f2(speedup) * "×"
        efficiency_text = speedup === nothing ? "N/A" :
                          _schema_f1((speedup / w) * 100.0) * "%"

        push!(scaling_rows,
              "| $(w) | $(_schema_f3(wall_med)) | $(_schema_f1(matches_hr_med)) | " *
              "$(_schema_grouped_f1(cands_med)) | $(speedup_text) | $(efficiency_text) |")

        walls_by_repeat = Dict{Int,Float64}()
        for r in rows
            walls_by_repeat[_schema_to_int(_schema_require(r, "repeat_index"))] =
                _schema_to_float(_schema_require(r, "wall_seconds"))
        end
        repeat_values = String[haskey(walls_by_repeat, r) ?
                               _schema_f3(walls_by_repeat[r]) : "-"
                               for r in repeat_indices]
        push!(repeat_rows, "| $(w) | " * join(repeat_values, " | ") * " |")

        # Latencies.
        mean_dec = _median(_schema_to_float(_schema_require(r, "decision_mean_seconds"))
                           for r in rows)
        p50_dec = _median(_schema_to_float(_schema_require(r, "decision_p50_seconds"))
                          for r in rows)
        p95_dec = _median(_schema_to_float(_schema_require(r, "decision_p95_seconds"))
                          for r in rows)
        verif_out = _median(_schema_to_float(_schema_require(
            r, "verification_and_output_seconds")) for r in rows)
        push!(latency_rows,
              "| $(w) | $(_schema_f3(mean_dec)) | $(_schema_f3(p50_dec)) | " *
              "$(_schema_f3(p95_dec)) | $(_schema_f4(verif_out)) |")

        # Phases.
        sim_p = _median(_schema_to_float(_schema_require(r, "sim_phase_seconds"))
                        for r in rows)
        reset_p = _median(_schema_to_float(_schema_require(
            r, "candidate_reset_phase_seconds")) for r in rows)
        sel_p = _median(_schema_to_float(_schema_require(r, "selection_phase_seconds"))
                        for r in rows) * 1000.0
        shot_p = _median(_schema_to_float(_schema_require(
            r, "actual_shot_phase_seconds")) for r in rows) * 1000.0
        ckpt_p = _median(_schema_to_float(_schema_require(r, "checkpoint_phase_seconds"))
                         for r in rows) * 1000.0
        push!(phase_rows,
              "| $(w) | $(_schema_f3(sim_p)) | $(_schema_f3(reset_p)) | " *
              "$(_schema_f3(sel_p)) | $(_schema_f3(shot_p)) | $(_schema_f3(ckpt_p)) |")
    end

    # Match summary table (from first trial's matches).
    match_table_rows = String[]
    if !isempty(matches_rows)
        first_trial_id = !isempty(trials_rows) ?
                         _schema_require(trials_rows[1], "trial_id") :
                         _schema_require(matches_rows[1], "trial_id")
        t1_matches = Any[]
        for m in matches_rows
            if _schema_row_get(m, "trial_id", nothing) == first_trial_id
                push!(t1_matches, m)
            end
        end
        sort!(t1_matches; by=m -> _schema_to_int(_schema_require(m, "match_id")))

        for m in t1_matches
            p1_score = _schema_grouped_int(_schema_to_bigint(
                _schema_require(m, "player1_score")))
            p2_score = _schema_grouped_int(_schema_to_bigint(
                _schema_require(m, "player2_score")))
            push!(match_table_rows,
                  "| $(_schema_py_str(_schema_require(m, "match_id"))) | $(p1_score) | " *
                  "$(p2_score) | $(_schema_py_str(_schema_require(m, "winner"))) | " *
                  "$(_schema_py_str(_schema_require(m, "turns"))) | " *
                  "$(_schema_py_str(_schema_require(m, "termination_reason"))) |")
        end
    end

    # Memory summary.
    rss_values = Int[]
    peak_rss_values = Int[]
    for r in trials_rows
        rss = _schema_row_get(r, "process_rss_bytes", nothing)
        if _schema_truthy(rss) && rss != ""
            push!(rss_values, _schema_to_int(rss))
        end
        peak_rss = _schema_row_get(r, "process_peak_rss_bytes", nothing)
        if _schema_truthy(peak_rss) && peak_rss != ""
            push!(peak_rss_values, _schema_to_int(peak_rss))
        end
    end

    rss_summary = ""
    if !isempty(rss_values) && !isempty(peak_rss_values)
        min_rss_mib = minimum(rss_values) / (1024 * 1024)
        max_rss_mib = maximum(rss_values) / (1024 * 1024)
        peak_mib = maximum(peak_rss_values) / (1024 * 1024)
        rss_summary = "Process RSS after output ranges from " *
            "**$(_schema_f1(min_rss_mib)) to $(_schema_f1(max_rss_mib)) MiB**.\n" *
            "Cumulative process peak RSS is **$(_schema_f1(peak_mib)) MiB**."
    end

    importer_section = ""
    if _schema_truthy(importer)
        imp = _schema_dict(importer)
        importer_section = "## Importer Provenance\n\n" *
            "- **Imported at**: `$(_schema_py_str(_schema_row_get(imp, "imported_at_utc", nothing)))`\n" *
            "- **Importer Git revision**: `$(_schema_py_str(_schema_row_get(imp, "importer_git_revision", nothing)))`\n" *
            "- **Legacy source file**: `$(_schema_py_str(_schema_row_get(imp, "legacy_baseline_file", nothing)))`\n" *
            "- **Notes**: $(_schema_py_str(_schema_row_get(imp, "notes", "None")))\n"
    end

    artifacts = _schema_dict(_schema_row_get(manifest, "artifacts", Dict{String,Any}()))
    canonical_history = _schema_dict(_schema_row_get(
        artifacts, "canonical_gameplay_history", Dict{String,Any}()))

    io = IOBuffer()
    print(io, "# Benchmark Run: `", run_id, "`\n\n")
    print(io, "- **Benchmark**: `", benchmark, "`\n")
    print(io, "- **Workload**: `", workload_id, "`\n")
    print(io, "- **Status**: `",
          _schema_py_str(_schema_row_get(manifest, "status", "unknown")), "`\n")
    print(io, "- **Timestamp (UTC)**: `", timestamp, "`\n")
    print(io, "- **Host**: `", _schema_py_str(_schema_row_get(host, "host_id", "unknown")),
          "` (`", _schema_py_str(_schema_row_get(host, "cpu_model", "unknown")), "`, ",
          _schema_py_str(_schema_row_get(host, "physical_cores", "?")),
          " physical cores / ",
          _schema_py_str(_schema_row_get(host, "cpu_threads", "?")), " threads)\n")
    print(io, "- **Runtime**: Julia `",
          _schema_py_str(_schema_row_get(runtime, "julia_version", "unknown")),
          "` with `",
          _schema_py_str(_schema_row_get(runtime, "julia_threads", "?")), "` threads\n")
    print(io, "- **Git revision**: `",
          _schema_py_str(_schema_row_get(source, "git_revision", "unknown")),
          "` (dirty: `",
          _schema_py_str(_schema_row_get(source, "git_dirty", false)), "`)\n")
    print(io, "- **Harness fingerprint**: `",
          _schema_py_str(_schema_row_get(source, "harness_fingerprint", "unknown")), "`\n")
    print(io, "- **Canonical gameplay hash**: `",
          _schema_py_str(_schema_row_get(canonical_history, "sha256", "unknown")), "`\n")

    print(io, "\n## Worker Scaling\n\n")
    print(io, "Summary metrics (medians across ", repetitions, "):\n\n")
    print(io, "| Workers | Campaign wall (s) | Completed matches/hour | ",
          "Candidates/second | Speedup | Efficiency |\n")
    print(io, "| ---: | ---: | ---: | ---: | ---: | ---: |\n")
    print(io, join(scaling_rows, "\n"), "\n\n")

    print(io, "### Wall Time by Repeat\n\n")
    print(io, repeat_header, "\n")
    print(io, repeat_separator, "\n")
    print(io, join(repeat_rows, "\n"), "\n\n")

    print(io, "### Decision Latencies\n\n")
    print(io, "| Workers | Mean decision (s) | p50 decision (s) | p95 decision (s) | ",
          "Verification/output (s) |\n")
    print(io, "| ---: | ---: | ---: | ---: | ---: |\n")
    print(io, join(latency_rows, "\n"), "\n\n")

    print(io, "### Phase Durations\n\n")
    print(io, "Values are summed worker wall durations across all matches:\n\n")
    print(io, "| Workers | Simulation (s) | Candidate reset (s) | Selection (ms) | ",
          "Actual shot (ms) | Checkpoint (ms) |\n")
    print(io, "| ---: | ---: | ---: | ---: | ---: | ---: |\n")
    print(io, join(phase_rows, "\n"), "\n\n")
    print(io, rss_summary)
    print(io, "\n\n## Match Results\n\n")
    print(io, "Seeded matches (",
          _schema_py_str(_schema_row_get(workload, "games", 8)),
          " matches per campaign, ", string(length(trials_rows)), " trials, ",
          completion_summary, "):\n\n")
    print(io, "| Match | Player 1 score | Player 2 score | Winner | Turns | Termination |\n")
    print(io, "| --- | ---: | ---: | ---: | ---: | --- |\n")
    print(io, join(match_table_rows, "\n"), "\n\n")

    print(io, "## Workload Configuration\n\n")
    print(io, "- Mode: `", _schema_py_str(_schema_row_get(workload, "mode", "1v1")), "`\n")
    print(io, "- Matches: `", _schema_py_str(_schema_row_get(workload, "games", 8)), "`\n")
    print(io, "- Base seed: `",
          _schema_py_str(_schema_row_get(workload, "base_seed", 20261024)), "`\n")
    print(io, "- Candidates per turn: `",
          _schema_py_str(_schema_row_get(workload, "candidate_count", 1801)), "`\n")
    print(io, "- Level: `", _schema_py_str(_schema_row_get(workload, "level_file", nothing)),
          "` (`", _schema_py_str(_schema_row_get(workload, "level_sha256", nothing)), "`)\n")
    print(io, "- Config: `",
          _schema_py_str(_schema_row_get(workload, "config_file", nothing)),
          "` (`", _schema_py_str(_schema_row_get(workload, "config_sha256", nothing)),
          "`)\n")
    print(io, "\n")
    print(io, importer_section)
    print(io, "\n## Artifacts\n\n")
    print(io, "- Canonical gameplay history: ",
          artifact_link("canonical_gameplay_history"), "\n")
    print(io, "- Full archive bundle: ", artifact_link("archive_bundle"), "\n")

    return String(take!(io))
end
