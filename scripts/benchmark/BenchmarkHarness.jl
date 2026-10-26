# Julia benchmark-execution harness.
#
# This module is the Julia successor to the Python benchmark-execution path:
#   scripts/run_campaign_benchmark.py
#   scripts/bench_process.py
#   scripts/sync_campaign_config.py
#   the runner-facing subset of benchmark_schema.py / validate_benchmark.py /
#   generate_benchmark_index.py
#
# It is included by the executable scripts with:
#   include(joinpath(@__DIR__, "benchmark", "BenchmarkHarness.jl"))
#   using .BenchmarkHarness
#
# See tmp/julia_harness/DESIGN.md for the frozen interface contract.
module BenchmarkHarness

using JSON
using SHA
using Printf
using Dates
import PeggleSim: canonical_json

include("schema.jl")
include("harness.jl")
include("validator.jl")
include("index.jl")

export SCHEMA_VERSION, PROTOCOL_VERSION, MAX_SAFE_INTEGER,
    HARNESS_DEFAULT_FILES, INDEX_CSV_COLUMNS, TRIALS_CSV_COLUMNS,
    MATCHES_CSV_COLUMNS, CsvTable,
    read_csv_rows, write_csv_rows,
    sha256_bytes, sha256_file,
    compute_harness_fingerprint, save_canonical_gameplay_history,
    create_artifact_archive, archive_member_bytes, archive_member_size,
    load_manifest, save_manifest, load_checks, save_checks,
    generate_run_readme,
    get_git_info, reserve_run, create_archive_exclusive, harness_files,
    capture_source_snapshot, collect_host_metadata, extract_rss_bytes,
    BenchmarkValidator, validate!, generate_index

end # module
