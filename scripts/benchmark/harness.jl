# ==============================================================================
# Harness helpers: Git provenance, run reservation, exclusive archives, the
# Julia-era harness manifest, source snapshots, host metadata, and RSS
# extraction.
#
# Ported from scripts/run_campaign_benchmark.py. This file is included inside
# the BenchmarkHarness module after schema.jl: it declares no module and adds
# no imports. It relies on sha256_file, create_artifact_archive, save_manifest,
# and HARNESS_DEFAULT_FILES from schema.jl.
# ==============================================================================

# Fixed part of the source manifest. Globbed files are added in harness_files.
const _HARNESS_FIXED_FILES = String[
    "campaigns/ribbon/config.source.lua",
    "campaigns/ribbon/game.source.lua",
    "fixtures/matches/rules.v1.json",
    "julia/PeggleSim/Manifest.toml",
    "julia/PeggleSim/Project.toml",
    "scripts/bench_process.jl",
    "scripts/run_campaign_benchmark.jl",
    "scripts/sync_campaign_config.jl",
    "scripts/verify_reference.sh",
    "tools/canonical_json.lua",
    "tools/capture_match_rules.lua",
]

# Directories whose Julia sources belong to the Julia-era harness.
const _HARNESS_JULIA_DIRS = ("julia/PeggleSim/src", "julia/PeggleSim/bin", "scripts/benchmark")

# Top-level roots that may contribute untracked source files to a snapshot.
const _HARNESS_SOURCE_ROOTS = ("julia", "scripts", "tools", "campaigns", "fixtures", "native")

# ==============================================================================
# Git provenance
# ==============================================================================

"""
    get_git_info(root_dir) -> (git_revision, git_dirty, git_status)

Return the current commit (or `"unknown"`), whether the worktree is dirty, and
the raw `git status --short` output. A failure to inspect the status is fatal,
matching the Python runner.
"""
function get_git_info(root_dir)::Tuple{String,Bool,String}
    root = String(root_dir)

    rev = try
        String(strip(read(pipeline(`git -C $root rev-parse HEAD`, stderr=devnull), String)))
    catch
        "unknown"
    end

    status = try
        read(pipeline(`git -C $root status --short`, stderr=devnull), String)
    catch
        throw(ErrorException("Cannot inspect source Git status"))
    end

    return (rev, !isempty(strip(status)), status)
end

# ==============================================================================
# Run reservation and exclusive publication
# ==============================================================================

"""
    reserve_run(benchmarks_dir, run_id) -> staging_path

Validate `run_id` as a single safe path component and reserve
`<benchmarks_dir>/.staging/<run_id>` exclusively. Existing runs, staging
directories, or published archives make the reservation fail: recorded evidence
is never modified.
"""
function reserve_run(benchmarks_dir, run_id)::String
    id = String(run_id)
    occursin(r"\A[A-Za-z0-9][A-Za-z0-9_.-]*\z", id) ||
        throw(ArgumentError("run_id must be a single safe path component"))

    benchmarks = String(benchmarks_dir)
    staging = joinpath(benchmarks, ".staging", id)

    for existing in (staging,
                     joinpath(benchmarks, "runs", id),
                     joinpath(benchmarks, "artifacts", id * ".tar.gz"))
        ispath(existing) &&
            throw(ErrorException("Run ID already exists: $existing; use a new run ID"))
    end

    mkpath(dirname(staging))
    mkdir(staging)  # exclusive reservation also protects concurrent invocations
    return staging
end

"""
    create_archive_exclusive(path, items) -> (sha256, size_bytes)

Create `<path>.partial` exclusively, build the archive there, and publish it
without replacing an existing target. A partial created by this call is removed
on failure; a target that already exists is left byte-identical and the call
throws. A partial owned by another invocation is never reused or removed.
"""
function create_archive_exclusive(path, items)::Tuple{String,Int}
    target = String(path)
    mkpath(dirname(target))
    partial = target * ".partial"
    reserved = false

    try
        # O_CREAT | O_EXCL reserves the partial name; a partial owned by a
        # concurrent or crashed invocation is never reused (nor removed here).
        fd = Base.Filesystem.open(partial,
                                  Base.Filesystem.JL_O_CREAT |
                                  Base.Filesystem.JL_O_EXCL |
                                  Base.Filesystem.JL_O_WRONLY,
                                  0o666)
        close(fd)
        reserved = true

        digest, size = create_artifact_archive(partial, items)

        try
            # A hard link fails atomically with EEXIST if the target appeared.
            Base.Filesystem.hardlink(partial, target)
        catch
            ispath(target) && rethrow()
            # Filesystems without hard links: rename without replacing.
            mv(partial, target; force=false)
        end

        return (digest, size)
    finally
        # Only clean up a partial this call created.
        reserved && ispath(partial) && rm(partial; force=true)
    end
end

# ==============================================================================
# Harness manifest
# ==============================================================================

"""
    harness_files(root_dir) -> Vector{String}

Return the sorted, unique, repo-relative manifest of every source file that
belongs to the Julia-era benchmark harness.
"""
function harness_files(root_dir)::Vector{String}
    root = String(root_dir)
    paths = copy(_HARNESS_FIXED_FILES)

    for directory in _HARNESS_JULIA_DIRS
        directory_path = joinpath(root, directory)
        isdir(directory_path) || continue
        for entry in readdir(directory_path)
            endswith(entry, ".jl") || continue
            full_path = joinpath(directory_path, entry)
            isfile(full_path) && push!(paths, relpath(abspath(full_path), abspath(root)))
        end
    end

    native_dir = joinpath(root, "native")
    if isdir(native_dir)
        for (dir_path, _dirs, files) in walkdir(native_dir)
            for entry in files
                splitext(entry)[2] in (".c", ".h", ".toml") || continue
                full_path = joinpath(dir_path, entry)
                isfile(full_path) && push!(paths, relpath(abspath(full_path), abspath(root)))
            end
        end
    end

    return sort(unique(paths))
end

# ==============================================================================
# Source snapshot
# ==============================================================================

"""
    capture_source_snapshot(root_dir, staging_dir; extra_paths=String[]) ->
        (snapshot_path, source_hashes)

Save `git diff --binary HEAD` and `git status --porcelain`, hash the harness
manifest plus any extra source paths and untracked files under Julia-era source
roots, write `source_files.json`, and bundle it all into
`source_snapshot.tar.gz`.

`extra_paths` may be absolute or relative (relative entries resolve against the
current working directory, like the Python runner); every entry must live inside
the repository, and only the repo-relative name is recorded.
"""
function capture_source_snapshot(root_dir, staging_dir;
                                 extra_paths=String[])::Tuple{String,Dict{String,String}}
    root = String(root_dir)
    staging = String(staging_dir)

    patch = read(pipeline(`git -C $root diff --binary HEAD`))
    patch_path = joinpath(staging, "git_diff.patch")
    write(patch_path, patch)

    paths = Set{String}(harness_files(root))
    for extra_path in extra_paths
        push!(paths, _harness_repo_relative(root, extra_path))
    end

    # Include all untracked files under source/input roots, even new helpers.
    untracked = read(pipeline(`git -C $root ls-files --others --exclude-standard -z`))
    for raw_name in split(String(untracked), '\0')
        isempty(raw_name) && continue
        name = String(raw_name)
        first(split(name, '/')) in _HARNESS_SOURCE_ROOTS || continue
        push!(paths, name)
    end

    hashes = Dict{String,String}()
    for name in sort(collect(paths))
        full_path = joinpath(root, name)
        isfile(full_path) && (hashes[name] = sha256_file(full_path))
    end

    status_path = joinpath(staging, "git_status.txt")
    write(status_path, read(pipeline(`git -C $root status --porcelain`)))

    inventory = joinpath(staging, "source_files.json")
    save_manifest(inventory, Dict{String,Any}(
        "files" => hashes,
        "git_diff_sha256" => sha256_file(patch_path),
        "restore" => "Checkout source.git_revision, apply git_diff.patch with git apply --binary, then overlay source/.",
    ))

    items = Tuple{String,String}[]
    for name in sort(collect(keys(hashes)))
        push!(items, (joinpath(root, name), "source/$name"))
    end
    append!(items, Tuple{String,String}[
        (patch_path, basename(patch_path)),
        (status_path, basename(status_path)),
        (inventory, basename(inventory)),
    ])

    snapshot = joinpath(staging, "source_snapshot.tar.gz")
    create_artifact_archive(snapshot, items)
    return (snapshot, hashes)
end

# ==============================================================================
# Host metadata
# ==============================================================================

"""
    collect_host_metadata() -> Dict{String,Any}

Collect host identity and CPU/memory/cgroup details. Linux values come from
`uname(2)`, `/proc`, `/sys`, `Sys.total_memory()`, and `lscpu`; other platforms
fall back to Julia's build/runtime identifiers.
"""
function collect_host_metadata()::Dict{String,Any}
    uname = _harness_uname()

    host_id = uname === nothing ? gethostname() : uname.nodename
    isempty(host_id) && (host_id = gethostname())
    machine = uname === nothing ? string(Sys.ARCH) : uname.machine
    isempty(machine) && (machine = string(Sys.ARCH))
    kernel = uname === nothing ? string(Sys.KERNEL) : uname.sysname
    isempty(kernel) && (kernel = string(Sys.KERNEL))

    os_release = _harness_read_text("/etc/os-release")

    # CPU info from /proc/cpuinfo.
    cpu_model = "unknown"
    physical_cores = Sys.CPU_THREADS > 0 ? Int(Sys.CPU_THREADS) : 1
    cpuinfo_text = _harness_read_text("/proc/cpuinfo")
    if !isempty(cpuinfo_text)
        core_ids = Set{String}()
        for line in split(cpuinfo_text, '\n')
            if startswith(line, "model name") && cpu_model == "unknown"
                parts = split(line, ':'; limit=2)
                length(parts) == 2 && (cpu_model = String(strip(parts[2])))
            end
            if startswith(line, "core id")
                parts = split(line, ':'; limit=2)
                length(parts) == 2 && push!(core_ids, strip(parts[2]))
            end
        end
        isempty(core_ids) || (physical_cores = length(core_ids))
    end

    cpu_threads = Sys.CPU_THREADS > 0 ? Int(Sys.CPU_THREADS) : physical_cores

    total_memory_bytes = try
        Int(Sys.total_memory())
    catch
        0
    end

    # CPU governors: equivalent to glob("cpu*/cpufreq/scaling_governor").
    governors = String[]
    try
        governors_dir = "/sys/devices/system/cpu"
        if isdir(governors_dir)
            for entry in readdir(governors_dir)
                startswith(entry, "cpu") || continue
                governor_path = joinpath(governors_dir, entry, "cpufreq", "scaling_governor")
                isfile(governor_path) || continue
                value = try
                    strip(_harness_read_text(governor_path))
                catch
                    ""
                end
                isempty(value) || value in governors || push!(governors, value)
            end
        end
    catch
    end
    isempty(governors) && push!(governors, "unknown")

    # Allowed CPUs: /proc/self/status Cpus_allowed_list is the sched_getaffinity
    # equivalent available to pure Julia.
    allowed_cpus = Int[]
    for line in split(_harness_read_text("/proc/self/status"), '\n')
        startswith(line, "Cpus_allowed_list:") || continue
        parts = split(line, ':'; limit=2)
        length(parts) == 2 || continue
        allowed_cpus = _harness_parse_cpu_list(parts[2])
        break
    end
    if isempty(allowed_cpus)
        fallback_threads = cpu_threads > 0 ? cpu_threads : 1
        allowed_cpus = collect(0:(fallback_threads - 1))
    else
        sort!(unique!(allowed_cpus))
    end

    # Cgroup cpuset.
    cgroup_cpuset = ""
    for cpuset_path in ("/sys/fs/cgroup/cpuset.cpus", "/sys/fs/cgroup/cpuset/cpuset.cpus")
        isfile(cpuset_path) || continue
        value = try
            strip(_harness_read_text(cpuset_path))
        catch
            continue
        end
        cgroup_cpuset = String(value)
        break
    end
    if isempty(cgroup_cpuset) && !isempty(allowed_cpus)
        cgroup_cpuset = string(minimum(allowed_cpus), "-", maximum(allowed_cpus))
    end

    # lscpu, when installed.
    lscpu_str = try
        read(pipeline(`lscpu`, stderr=devnull), String)
    catch
        ""
    end

    processor = _harness_processor()
    cpu_family = isempty(processor) ? "znver2" : processor

    return Dict{String,Any}(
        "host_id" => host_id,
        "machine" => machine,
        "kernel" => kernel,
        "os_release" => os_release,
        "cpu_model" => cpu_model,
        "cpu_family" => cpu_family,
        "physical_cores" => physical_cores,
        "cpu_threads" => cpu_threads,
        "total_memory_bytes" => total_memory_bytes,
        "cpu_governors" => governors,
        "allowed_cpus" => allowed_cpus,
        "cgroup_cpuset" => cgroup_cpuset,
        "lscpu" => lscpu_str,
    )
end

# ==============================================================================
# RSS extraction
# ==============================================================================

"""
    extract_rss_bytes(process_memory) -> String

Return the first `VmRSS:` value from `/proc/self/status` lines converted from
KiB to a decimal byte count, or `""` when unavailable.
"""
function extract_rss_bytes(process_memory)::String
    process_memory === nothing && return ""
    lines = process_memory isa AbstractString ? split(process_memory, '\n') : process_memory
    for line in lines
        text = String(line)
        startswith(text, "VmRSS:") || continue
        parts = split(text)
        length(parts) >= 2 || continue
        kb = tryparse(Int, parts[2])
        kb === nothing && continue
        return string(kb * 1024)
    end
    return ""
end

# ==============================================================================
# Internal helpers
# ==============================================================================

function _harness_repo_relative(root::String, path)::String
    root_absolute = abspath(root)
    target = abspath(String(path))
    target == root_absolute && return "."
    prefix = endswith(root_absolute, "/") ? root_absolute : root_absolute * "/"
    startswith(target, prefix) ||
        throw(ArgumentError("path is outside the repository: $(path)"))
    return String(relpath(target, root_absolute))
end

function _harness_read_bytes(path::AbstractString)::Vector{UInt8}
    data = UInt8[]
    open(path, "r") do io
        buffer = Vector{UInt8}(undef, 65536)
        while true
            count = readbytes!(io, buffer, length(buffer))
            count == 0 && break
            append!(data, view(buffer, 1:count))
        end
    end
    return data
end

function _harness_read_text(path::AbstractString)::String
    isfile(path) || return ""
    try
        # A single read(io, String) can return a short chunk for procfs/sysfs
        # files (their st_size is 0), so drain the file explicitly.
        return String(_harness_read_bytes(path))
    catch
        return ""
    end
end

function _harness_uname()
    Sys.islinux() || return nothing
    buffer = zeros(UInt8, 6 * 65)  # struct utsname: six 65-byte fields on Linux
    status = try
        ccall(:uname, Cint, (Ptr{UInt8},), buffer)
    catch
        return nothing
    end
    status == 0 || return nothing
    return (
        sysname = _harness_utsname_field(buffer, 0),
        nodename = _harness_utsname_field(buffer, 1),
        machine = _harness_utsname_field(buffer, 4),
    )
end

function _harness_utsname_field(buffer::Vector{UInt8}, index::Integer)::String
    offset = index * 65
    count = 0
    while count < 65 && buffer[offset + count + 1] != 0x00
        count += 1
    end
    return String(buffer[(offset + 1):(offset + count)])
end

function _harness_parse_cpu_list(value)::Vector{Int}
    cpus = Int[]
    for raw_piece in split(String(value), ',')
        piece = strip(raw_piece)
        isempty(piece) && continue
        if occursin('-', piece)
            bounds = split(piece, '-'; limit=2)
            length(bounds) == 2 || continue
            low = tryparse(Int, strip(bounds[1]))
            high = tryparse(Int, strip(bounds[2]))
            (low === nothing || high === nothing) && continue
            low <= high || continue
            append!(cpus, low:high)
        else
            cpu = tryparse(Int, piece)
            cpu === nothing || push!(cpus, cpu)
        end
    end
    return cpus
end

function _harness_processor()::String
    # Python's platform.processor() shells out to `uname -p`, which reports
    # "unknown" (normalized to "") on x86 Linux. Mirror that observable value
    # without invoking uname; elsewhere Sys.ARCH is the processor identifier.
    if Sys.islinux() && Sys.ARCH in (:x86_64, :i686)
        return ""
    end
    return string(Sys.ARCH)
end
