# Benchmark run validator (Julia port of scripts/validate_benchmark.py).
#
# Included inside the BenchmarkHarness module; no module declaration and no
# `using` statements here. `JSON`, `SHA`, `Printf` and `Dates` come from the
# enclosing module, as do the schema helpers from schema.jl.

const _VALID_STATUSES = ("completed", "failed", "interrupted", "invalid")
const _PARTIAL_STATUSES = ("failed", "interrupted", "invalid")
const _REQUIRED_CHECKS = ("reference_files", "current_config", "match_rule_oracle", "gameplay_identity")
const _TRIALS_OPTIONAL_COLUMNS = ("process_rss_bytes", "process_peak_rss_bytes", "allocated_bytes", "gc_collections", "gc_seconds")
const _TRIALS_OPTIONAL_INTEGER_COLUMNS = ("process_rss_bytes", "process_peak_rss_bytes", "allocated_bytes", "gc_collections")

mutable struct BenchmarkValidator
    run_dir::String
    root_dir::String
    index_path::Union{Nothing,String}
    errors::Vector{String}
    warnings::Vector{String}
end

function BenchmarkValidator(run_dir; index_path=nothing, root_dir=pwd())
    run = String(abspath(String(run_dir)))
    # Python: root_dir or Path.cwd().
    root = String(abspath(root_dir === nothing ? pwd() : String(root_dir)))
    index = index_path === nothing ? nothing : String(abspath(String(index_path)))
    return BenchmarkValidator(run, root, index, String[], String[])
end

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

log_error(v::BenchmarkValidator, msg) = push!(v.errors, String(msg))
log_warning(v::BenchmarkValidator, msg) = push!(v.warnings, String(msg))

# Python truthiness for JSON-decoded values.
function _truthy(value)
    value === nothing && return false
    value === missing && return false
    if value isa Bool
        return value
    elseif value isa AbstractString
        return !isempty(value)
    elseif value isa Number
        return value != 0
    elseif value isa AbstractArray || value isa AbstractDict || value isa AbstractSet
        return !isempty(value)
    end
    return true
end

_py_string(value) = value === nothing ? "None" : value isa AbstractString ? "'$value'" : string(value)

# Path join mirroring Python's `Path / other`: an absolute RHS wins.
_resolve_path(base::AbstractString, path::AbstractString) = isabspath(path) ? String(path) : joinpath(base, path)

_as_dict(value) = value isa AbstractDict ? value : nothing

function _dict_or_empty(value)
    d = _as_dict(value)
    return d === nothing ? Dict{String,Any}() : d
end

_has_manifest(manifest) = manifest isa AbstractDict && !isempty(manifest)

function _to_int(value)
    if value isa Integer
        return Int64(value)
    end
    value isa AbstractString || throw(ArgumentError("not an integer: $(_py_string(value))"))
    text = strip(value)
    isempty(text) && throw(ArgumentError("not an integer: ''"))
    return parse(Int64, text)
end

function _to_float(value)
    if value isa Real
        return Float64(value)
    end
    value isa AbstractString || throw(ArgumentError("not a number: $(_py_string(value))"))
    text = strip(value)
    isempty(text) && throw(ArgumentError("not a number: ''"))
    return parse(Float64, text)
end

function valid_sha(value)
    value isa AbstractString || return false
    length(value) == 64 || return false
    return all(c -> ('0' <= c <= '9') || ('a' <= c <= 'f'), value)
end

# Errors Python would surface as ValueError/TypeError/KeyError/OSError and that
# callers convert into validator messages rather than crashing.
function _is_data_error(err)
    return err isa Union{KeyError,ArgumentError,InexactError,MethodError,BoundsError,
                         OverflowError,DomainError,SystemError,Base.IOError}
end

function _error_message(err)
    return sprint(showerror, err)
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function validate!(v::BenchmarkValidator)::Bool
    if !isdir(v.run_dir)
        log_error(v, "Run directory does not exist or is not a directory: $(v.run_dir)")
        return false
    end

    manifest_path = joinpath(v.run_dir, "manifest.json")
    trials_path = joinpath(v.run_dir, "trials.csv")
    matches_path = joinpath(v.run_dir, "matches.csv")
    checks_path = joinpath(v.run_dir, "checks.json")

    empty!(v.errors)
    empty!(v.warnings)

    manifest = nothing
    if !isfile(manifest_path)
        log_error(v, "Missing required file: $manifest_path")
    else
        raw = nothing
        try
            raw = load_manifest(manifest_path)
            validate_manifest(v, raw)
        catch err
            log_error(v, "Failed to parse or validate manifest.json: $(_error_message(err))")
        end
        # Python keeps the parsed object even when validate_manifest raises.
        if raw isa AbstractDict
            manifest = raw
        end
    end

    partial = _has_manifest(manifest) && get(manifest, "status", nothing) in _PARTIAL_STATUSES

    trials_rows = Dict{String,String}[]
    if !isfile(trials_path) && !partial
        log_error(v, "Missing required file: $trials_path")
    elseif isfile(trials_path)
        try
            table = read_csv_rows(trials_path)
            trials_rows = table.rows
            validate_trials_csv(v, table, manifest)
        catch err
            log_error(v, "Failed to read or validate trials.csv: $(_error_message(err))")
        end
    end

    matches_rows = Dict{String,String}[]
    if !isfile(matches_path) && !partial
        log_error(v, "Missing required file: $matches_path")
    elseif isfile(matches_path)
        try
            table = read_csv_rows(matches_path)
            matches_rows = table.rows
            validate_matches_csv(v, table, manifest)
        catch err
            log_error(v, "Failed to read or validate matches.csv: $(_error_message(err))")
        end
    end

    if !isempty(trials_rows) && !isempty(matches_rows)
        try
            validate_consistency(v, trials_rows, matches_rows, manifest)
        catch err
            if _is_data_error(err)
                log_error(v, "Invalid table consistency data: $(_error_message(err))")
            else
                rethrow()
            end
        end
    end

    if !isfile(checks_path) && !partial
        log_error(v, "Missing required file: $checks_path")
    elseif isfile(checks_path)
        try
            checks = load_checks(checks_path)
            validate_checks(v, checks, manifest)
        catch err
            log_error(v, "Failed to parse or validate checks.json: $(_error_message(err))")
        end
    end

    if _has_manifest(manifest)
        try
            validate_artifacts(v, manifest)
            if !isempty(trials_rows) && !isempty(matches_rows)
                validate_history(v, manifest, trials_rows, matches_rows)
            end
        catch err
            if _is_data_error(err) || err isa JSON.ParserError
                log_error(v, "Invalid artifact data: $(_error_message(err))")
            else
                rethrow()
            end
        end
    end

    if v.index_path !== nothing
        validate_index(v, manifest)
    end

    return isempty(v.errors)
end

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

function validate_manifest(v::BenchmarkValidator, m)
    if !(m isa AbstractDict)
        throw(ArgumentError("manifest.json must be an object"))
    end

    partial = get(m, "status", nothing) in _PARTIAL_STATUSES
    required_keys = [
        "schema_version",
        "protocol_version",
        "run_id",
        "benchmark",
        "workload_id",
        "status",
        "timestamp_utc",
        "host",
        "runtime",
        "source",
        "workload",
        "artifacts",
    ]
    if partial
        required_keys = ["schema_version", "protocol_version", "run_id", "benchmark", "workload_id", "status", "timestamp_utc"]
    end
    for key in required_keys
        haskey(m, key) || log_error(v, "manifest.json missing required key '$key'")
    end

    schema_version = get(m, "schema_version", nothing)
    if schema_version != SCHEMA_VERSION
        log_error(v, "Unsupported result schema version: $schema_version")
    end
    protocol_version = get(m, "protocol_version", nothing)
    if protocol_version != PROTOCOL_VERSION
        log_error(v, "Unsupported measurement protocol version: $protocol_version")
    end

    status = get(m, "status", nothing)
    if !(status in _VALID_STATUSES)
        log_error(v, "manifest.json status '$status' not in valid set Set([\"completed\", \"failed\", \"interrupted\", \"invalid\"])")
    end

    run_id = get(m, "run_id", nothing)
    if run_id != basename(v.run_dir)
        log_error(v, "manifest.json run_id '$run_id' does not match directory name '$(basename(v.run_dir))'")
    end

    partial && return nothing

    # Host checks.
    host = get(m, "host", Dict{String,Any}())
    if !(host isa AbstractDict)
        log_error(v, "manifest.json 'host' must be an object")
    else
        for k in ("host_id", "machine", "cpu_model")
            if !haskey(host, k) || !_truthy(host[k])
                log_error(v, "manifest.json host missing or empty '$k'")
            end
        end
    end

    # Source / provenance checks.
    source = get(m, "source", Dict{String,Any}())
    if !(source isa AbstractDict)
        log_error(v, "manifest.json 'source' must be an object")
    else
        for k in ("git_revision", "git_dirty", "harness_entry_point", "harness_fingerprint")
            haskey(source, k) || log_error(v, "manifest.json source missing required provenance key '$k'")
        end
        if haskey(source, "git_dirty") && !(source["git_dirty"] isa Bool)
            log_error(v, "manifest.json source.git_dirty must be a boolean")
        end
        if get(source, "fingerprint_version", nothing) == "2"
            files = get(source, "harness_files", nothing)
            if !(files isa AbstractDict) || isempty(files) ||
               any(k -> !(k isa AbstractString) || !valid_sha(files[k]), keys(files))
                log_error(v, "Source fingerprint requires a nonempty path/SHA-256 manifest")
            else
                encoded = join([string(files[path], "  ", path, "\n") for path in sort(collect(keys(files)))])
                if sha256_bytes(collect(codeunits(encoded))) != get(source, "harness_fingerprint", nothing)
                    log_error(v, "Source harness fingerprint differs from harness_files manifest")
                end
            end
            if !(get(source, "run_kind", nothing) in ("official", "exploratory"))
                log_error(v, "manifest.json source.run_kind must be official or exploratory")
            end
            if get(source, "run_kind", nothing) == "official" && _truthy(get(source, "git_dirty", nothing))
                log_error(v, "Official benchmark runs require a committed source tree")
            end
            if _truthy(get(source, "git_dirty", nothing))
                snapshot = get(source, "source_snapshot", nothing)
                if !(snapshot isa AbstractDict) ||
                   !_truthy(get(snapshot, "archive_member", nothing)) ||
                   !valid_sha(get(snapshot, "sha256", nothing))
                    log_error(v, "Dirty source requires an archived source snapshot and SHA-256")
                end
            end
        end
    end

    # Workload checks.
    workload = get(m, "workload", Dict{String,Any}())
    if !(workload isa AbstractDict)
        log_error(v, "manifest.json 'workload' must be an object")
    else
        for k in ("mode", "games", "base_seed", "candidate_count")
            haskey(workload, k) || log_error(v, "manifest.json workload missing required key '$k'")
        end
    end

    # Artifact references.
    artifacts = get(m, "artifacts", Dict{String,Any}())
    if !(artifacts isa AbstractDict)
        log_error(v, "manifest.json 'artifacts' must be an object")
    else
        for art_key in ("canonical_gameplay_history", "archive_bundle")
            if !haskey(artifacts, art_key)
                log_error(v, "manifest.json artifacts missing '$art_key'")
            else
                item = artifacts[art_key]
                if !(item isa AbstractDict) || !_truthy(get(item, "path", nothing)) ||
                   !valid_sha(get(item, "sha256", nothing))
                    log_error(v, "manifest.json artifact '$art_key' must have 'path' and 'sha256'")
                end
            end
        end
    end

    return nothing
end

# ---------------------------------------------------------------------------
# CSV numbers / headers
# ---------------------------------------------------------------------------

function validate_number(v::BenchmarkValidator, row, column, context;
                         integer::Bool=false, positive::Bool=false, optional::Bool=false)
    value = get(row, column, nothing)
    if optional && value == ""
        return nothing
    end
    ok = false
    try
        if value === nothing
            throw(ArgumentError("missing value"))
        end
        if integer
            number = _to_int(value)
            ok = number >= 0 && !(positive && number == 0)
        else
            number = _to_float(value)
            ok = isfinite(number) && number >= 0 && !(positive && number == 0)
        end
    catch err
        ok = false
    end
    if !ok
        label = integer ? "integer" : "number"
        log_error(v, "$context: invalid $label in '$column': $(_py_string(value))")
    end
    return nothing
end

function validate_headers(v::BenchmarkValidator, table::CsvTable, expected::Vector{String}, filename::AbstractString)
    if isempty(table.rows)
        log_error(v, "$filename is empty")
        return nothing
    end
    if table.header != expected
        log_error(v, "$filename headers do not match schema")
    end
    declared = Set(table.header)
    for (idx, row) in enumerate(table.rows)
        malformed = length(row) != length(table.header) ||
                    any(k -> !(k in declared), keys(row)) ||
                    (haskey(row, "") && !("" in declared))
        if malformed
            log_error(v, "$filename row $idx has malformed column count")
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# trials.csv
# ---------------------------------------------------------------------------

function validate_trials_csv(v::BenchmarkValidator, table::CsvTable, manifest)
    validate_headers(v, table, TRIALS_CSV_COLUMNS, "trials.csv")
    seen = Set{String}()
    for (idx, row) in enumerate(table.rows)
        context = "trials.csv row $idx"
        trial_id = get(row, "trial_id", nothing)
        if !_truthy(trial_id) || (trial_id isa AbstractString && trial_id in seen)
            log_error(v, "$context: missing or duplicate trial_id $(_py_string(trial_id))")
        end
        if trial_id isa AbstractString
            push!(seen, trial_id)
        end
        if _has_manifest(manifest) && get(row, "run_id", nothing) != get(manifest, "run_id", nothing)
            log_error(v, "$context: run_id differs from manifest")
        end
        for col in ("execution_order", "repeat_index", "workers")
            validate_number(v, row, col, context; integer=true, positive=true)
        end
        for col in ("completed_matches", "candidates")
            validate_number(v, row, col, context; integer=true)
        end
        for col in TRIALS_CSV_COLUMNS[7:(end - 1)]
            col in ("completed_matches", "candidates") && continue
            validate_number(v, row, col, context;
                            integer=col in _TRIALS_OPTIONAL_INTEGER_COLUMNS,
                            optional=col in _TRIALS_OPTIONAL_COLUMNS)
        end
        if !(get(row, "mode", nothing) in ("sequential", "parallel"))
            log_error(v, "$context: invalid mode")
        end
        if !valid_sha(get(row, "gameplay_sha256", nothing))
            log_error(v, "$context: invalid gameplay SHA-256")
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# matches.csv
# ---------------------------------------------------------------------------

function validate_matches_csv(v::BenchmarkValidator, table::CsvTable, manifest)
    validate_headers(v, table, MATCHES_CSV_COLUMNS, "matches.csv")
    seen = Set{Tuple{String,String}}()
    for (idx, row) in enumerate(table.rows)
        context = "matches.csv row $idx"
        trial_id = get(row, "trial_id", nothing)
        match_id = get(row, "match_id", nothing)
        key = (trial_id, match_id)
        duplicate = trial_id isa AbstractString && match_id isa AbstractString &&
                    (trial_id, match_id) in seen
        if !_truthy(trial_id) || !_truthy(match_id) || duplicate
            log_error(v, "$context: missing or duplicate trial/match ID $(_py_string(trial_id)), $(_py_string(match_id))")
        end
        if trial_id isa AbstractString && match_id isa AbstractString
            push!(seen, (trial_id, match_id))
        end
        if _has_manifest(manifest) && get(row, "run_id", nothing) != get(manifest, "run_id", nothing)
            log_error(v, "$context: run_id differs from manifest")
        end
        for col in ("repeat_index", "workers", "match_id", "worker_index")
            validate_number(v, row, col, context; integer=true, positive=true)
        end
        for col in ("base_seed", "bot_seed_1", "bot_seed_2", "gameplay_seed", "turns", "candidates", "winner")
            validate_number(v, row, col, context; integer=true)
        end
        for col in ("wall_seconds", "sim_phase_seconds", "player1_score", "player2_score")
            validate_number(v, row, col, context)
        end
        if !(get(row, "completed", nothing) in ("true", "false"))
            log_error(v, "$context: completed must be true or false")
        end
        if !_truthy(get(row, "termination_reason", nothing))
            log_error(v, "$context: termination_reason is required")
        end
        if !valid_sha(get(row, "gameplay_sha256", nothing))
            log_error(v, "$context: invalid gameplay SHA-256")
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Table consistency
# ---------------------------------------------------------------------------

function validate_consistency(v::BenchmarkValidator, trials, matches, manifest=nothing)
    by_trial = Dict{String,Vector{Dict{String,String}}}()
    for trial in trials
        by_trial[trial["trial_id"]] = Dict{String,String}[]
    end
    for match in matches
        trial_id = get(match, "trial_id", nothing)
        if !(trial_id isa AbstractString) || !haskey(by_trial, trial_id)
            log_error(v, "matches.csv references unknown trial_id $(_py_string(trial_id))")
        else
            push!(by_trial[trial_id], match)
        end
    end

    for trial in trials
        trial_id = trial["trial_id"]
        group = by_trial[trial_id]
        completed = count(m -> get(m, "completed", nothing) == "true", group)
        if completed != _to_int(trial["completed_matches"])
            log_error(v, "Trial $trial_id: completed match count differs from matches.csv")
        end
        candidate_sum = 0
        for m in group
            candidate_sum += _to_int(m["candidates"])
        end
        if candidate_sum != _to_int(trial["candidates"])
            log_error(v, "Trial $trial_id: candidate sum differs from matches.csv")
        end
        if _has_manifest(manifest) && get(manifest, "status", nothing) == "completed"
            expected = get(_dict_or_empty(get(manifest, "workload", nothing)), "games", nothing)
            if length(group) != expected || completed != expected
                log_error(v, "Trial $trial_id: completed run must contain all $expected completed matches")
            end
        end
        for match in group
            match_id = get(match, "match_id", nothing)
            for field in ("workers", "repeat_index", "gameplay_sha256")
                if get(match, field, nothing) != get(trial, field, nothing)
                    log_error(v, "Trial $trial_id: match $match_id has inconsistent $field")
                end
            end
            worker_index = _to_int(match["worker_index"])
            worker_count = _to_int(trial["workers"])
            if !(1 <= worker_index <= worker_count)
                log_error(v, "Trial $trial_id: worker_index outside active worker count")
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# checks.json
# ---------------------------------------------------------------------------

function evidence_hash(v::BenchmarkValidator, path, manifest)
    bundle = get(_dict_or_empty(get(_dict_or_empty(get(manifest, "artifacts", nothing)), "archive_bundle", nothing)), "path", nothing)
    if _truthy(bundle)
        archive = _resolve_path(v.root_dir, String(bundle))
        if isfile(archive)
            data = nothing
            try
                data = archive_member_bytes(archive, String(path))
            catch err
                data = nothing
            end
            if data !== nothing
                return sha256_bytes(data)
            end
        end
    end
    for candidate in (_resolve_path(v.run_dir, String(path)), _resolve_path(v.root_dir, String(path)))
        if isfile(candidate)
            return sha256_file(candidate)
        end
    end
    return nothing
end

function validate_checks(v::BenchmarkValidator, checks, manifest=nothing)
    if !(checks isa AbstractDict) || get(checks, "schema_version", nothing) != SCHEMA_VERSION
        log_error(v, "checks.json must be an object with supported schema_version")
        return nothing
    end
    items = get(checks, "checks", nothing)
    if !(items isa AbstractVector)
        log_error(v, "checks.json checks must be an array")
        return nothing
    end
    completed = _has_manifest(manifest) && get(manifest, "status", nothing) == "completed"
    seen = Set{String}()
    for item in items
        if !(item isa AbstractDict)
            log_error(v, "checks.json record must be an object")
            continue
        end
        name = get(item, "name", nothing)
        if !(name isa AbstractString) || isempty(name) || name in seen
            log_error(v, "checks.json missing or duplicate name $(_py_string(name))")
            continue
        end
        push!(seen, name)
        status = get(item, "status", nothing)
        if !(status in ("passed", "failed", "not_collected"))
            log_error(v, "Check $name: invalid status $(_py_string(status))")
        end
        if completed && (status == "failed" || (name in _REQUIRED_CHECKS && status != "passed"))
            log_error(v, "Completed run has unsuccessful check $name: $(_py_string(status))")
        end
        if status == "passed"
            path = get(item, "evidence_path", nothing)
            digest = get(item, "evidence_sha256", nothing)
            if name == "candidate_count" && !_truthy(path) && !_truthy(digest)
                # Recomputed independently from canonical games and table rows.
                continue
            end
            if !_truthy(path) || !valid_sha(digest)
                log_error(v, "Passed check $name requires evidence path and SHA-256")
            elseif _has_manifest(manifest)
                actual = evidence_hash(v, path, manifest)
                if actual != digest
                    log_error(v, "Check $name: evidence missing or SHA-256 mismatch ($path)")
                end
            end
        end
    end
    if completed
        for name in sort(collect(setdiff(Set(_REQUIRED_CHECKS), seen)))
            log_error(v, "Completed run missing required check $name")
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Canonical history
# ---------------------------------------------------------------------------

function validate_history(v::BenchmarkValidator, manifest, trials, matches)
    artifacts = _dict_or_empty(get(manifest, "artifacts", nothing))
    artifact = _dict_or_empty(get(artifacts, "canonical_gameplay_history", nothing))
    path = get(artifact, "path", nothing)
    digest = get(artifact, "sha256", nothing)
    if !_truthy(path) || !_truthy(digest)
        return nothing
    end

    games = JSON.parsefile(_resolve_path(v.root_dir, String(path)))
    if !(games isa AbstractVector)
        throw(ArgumentError("canonical gameplay history must be an array"))
    end
    by_id = Dict{String,Any}()
    for game in games
        if !(game isa AbstractDict)
            throw(ArgumentError("canonical gameplay history entry must be an object"))
        end
        by_id[string(game["game"])] = game
    end
    if length(by_id) != length(games)
        log_error(v, "Canonical history has duplicate game IDs")
    end

    status = get(manifest, "status", nothing)
    if status == "completed" && any(g -> !_truthy(get(g, "completed", nothing)), games)
        log_error(v, "Completed run has incomplete games in canonical history")
    end
    workload = _dict_or_empty(get(manifest, "workload", nothing))
    if status == "completed" && length(games) != get(workload, "games", nothing)
        log_error(v, "Canonical history game count differs from workload")
    end

    for trial in trials
        if get(trial, "gameplay_sha256", nothing) != digest
            trial_id = get(trial, "trial_id", nothing)
            log_error(v, "Trial $trial_id: gameplay hash differs from canonical artifact")
        end
    end

    aim_count = get(workload, "candidate_count", nothing)
    for match in matches
        match_id = get(match, "match_id", nothing)
        game = match_id isa AbstractString ? get(by_id, match_id, nothing) : nothing
        if game === nothing
            log_error(v, "Match $(_py_string(match_id)) absent from canonical history")
            continue
        end
        for col in ("turns", "base_seed", "gameplay_seed", "termination_reason")
            if string(game[col]) != get(match, col, nothing)
                log_error(v, "Match $(_py_string(match_id)): $col differs from canonical history")
            end
        end
        if lowercase(string(game["completed"])) != get(match, "completed", nothing)
            log_error(v, "Match $(_py_string(match_id)): completion differs from canonical history")
        end
        bot_seeds = get(game, "bot_seeds", Any[0])
        player_scores = get(game, "player_scores", Any[0])
        winner = get(game, "winner", nothing)
        comparisons = (
            ("bot_seed_1", bot_seeds[1]),
            ("bot_seed_2", length(bot_seeds) > 1 ? bot_seeds[2] : 0),
            ("winner", _truthy(winner) ? winner : 0),
            ("player1_score", player_scores[1]),
            ("player2_score", length(player_scores) > 1 ? player_scores[2] : 0),
        )
        for (col, value) in comparisons
            if _to_float(match[col]) != value
                log_error(v, "Match $(_py_string(match_id)): $col differs from canonical history")
            end
        end
        if _truthy(aim_count) &&
           _to_int(match["candidates"]) != _to_int(game["turns"]) * _to_int(aim_count)
            log_error(v, "Match $(_py_string(match_id)): candidate count differs from turns × grid size")
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Artifacts
# ---------------------------------------------------------------------------

function validate_artifacts(v::BenchmarkValidator, manifest)
    artifacts = _dict_or_empty(get(manifest, "artifacts", nothing))
    source = _dict_or_empty(get(manifest, "source", nothing))

    snapshot = get(source, "source_snapshot", nothing)
    if snapshot isa AbstractDict && _truthy(get(snapshot, "archive_member", nothing))
        member_name = get(snapshot, "archive_member", nothing)
        if evidence_hash(v, member_name, manifest) != get(snapshot, "sha256", nothing)
            log_error(v, "Source snapshot is missing or has an invalid SHA-256")
        end
        bundle_path = get(_dict_or_empty(get(artifacts, "archive_bundle", nothing)), "path", nothing)
        if _truthy(bundle_path)
            archive = _resolve_path(v.root_dir, String(bundle_path))
            size = nothing
            try
                size = archive_member_size(archive, String(member_name))
            catch err
                size = nothing
            end
            if size === nothing
                log_error(v, "Unable to read archived source snapshot: member '$member_name' not found in archive")
            elseif size != get(snapshot, "size_bytes", nothing)
                log_error(v, "Source snapshot size differs from archived member")
            end
        end
    end

    # 1. Canonical gameplay history.
    c_art = _dict_or_empty(get(artifacts, "canonical_gameplay_history", nothing))
    rel_path = get(c_art, "path", nothing)
    expected_sha = get(c_art, "sha256", nothing)
    if _truthy(rel_path) && _truthy(expected_sha)
        full_path = _resolve_path(v.root_dir, String(rel_path))
        if !isfile(full_path)
            log_error(v, "Artifact canonical gameplay history file does not exist: $full_path")
        else
            actual_sha = sha256_file(full_path)
            if actual_sha != expected_sha
                log_error(v, "Artifact canonical gameplay history SHA-256 mismatch: expected $expected_sha, got $actual_sha")
            end
        end
    end

    # 2. Archive bundle.
    b_art = _dict_or_empty(get(artifacts, "archive_bundle", nothing))
    b_rel_path = get(b_art, "path", nothing)
    b_expected_sha = get(b_art, "sha256", nothing)
    b_size = get(b_art, "size_bytes", nothing)
    if _truthy(b_rel_path) && _truthy(b_expected_sha)
        b_full_path = _resolve_path(v.root_dir, String(b_rel_path))
        if !isfile(b_full_path)
            log_error(v, "Artifact archive bundle file does not exist: $b_full_path")
        else
            actual_sha = sha256_file(b_full_path)
            if actual_sha != b_expected_sha
                log_error(v, "Artifact archive bundle SHA-256 mismatch: expected $b_expected_sha, got $actual_sha")
            end
            if b_size !== nothing
                actual_size = filesize(b_full_path)
                if actual_size != b_size
                    log_error(v, "Artifact archive bundle size mismatch: recorded $b_size, actual $actual_size")
                end
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Optional index.csv consistency
# ---------------------------------------------------------------------------

function validate_index(v::BenchmarkValidator, manifest)
    index_path = v.index_path
    if index_path === nothing || !isfile(index_path)
        log_error(v, "Index file does not exist: $index_path")
        return nothing
    end

    table = nothing
    try
        table = read_csv_rows(index_path)
    catch err
        log_error(v, "Failed to read index.csv: $(_error_message(err))")
        return nothing
    end

    if isempty(table.rows)
        log_error(v, "index.csv is empty")
        return nothing
    end

    missing_headers = [h for h in INDEX_CSV_COLUMNS if !(h in table.header)]
    if !isempty(missing_headers)
        log_error(v, "index.csv missing headers: [$(join(["'$h'" for h in missing_headers], ", "))]")
    end

    if _has_manifest(manifest)
        run_id = get(manifest, "run_id", nothing)
        matching = [row for row in table.rows if get(row, "run_id", nothing) == run_id]
        if isempty(matching)
            log_error(v, "Run ID '$run_id' not found in index.csv ($index_path)")
        else
            if length(matching) != 1
                log_error(v, "index.csv duplicate run_id $(_py_string(run_id))")
            end
            row = matching[1]
            for field in ("benchmark", "status", "workload_id", "protocol_version", "schema_version")
                if get(row, field, nothing) != get(manifest, field, nothing)
                    log_error(v, "index.csv mismatch for field '$field': index has '$(get(row, field, nothing))', manifest has '$(get(manifest, field, nothing))'")
                end
            end
        end
    end
    return nothing
end
