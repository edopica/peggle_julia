"""Internal low-memory launcher for bench_process.jl's non-GNU-time backend."""

import json
import resource
import subprocess
import sys


def main():
    output, *command = sys.argv[1:]
    try:
        # Collect CHILDREN usage here, after Python has exec'd and discarded
        # Julia's address space. The workload inherits only this small launcher.
        status = subprocess.call(command)
        exit_code = 128 - status if status < 0 else status
        peak_kb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        if sys.platform == "darwin":
            peak_kb //= 1024
        result = {"exit_code": exit_code, "peak_rss_kb": peak_kb}
    except OSError as exc:
        result = {"exit_code": 127, "peak_rss_kb": None,
                  "error": f"command not found: {exc}"}
    with open(output, "w", encoding="utf-8") as stream:
        json.dump(result, stream)
    return result["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
