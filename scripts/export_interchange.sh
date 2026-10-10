#!/usr/bin/env bash
# Export the pinned reference's static levels and configuration into the
# versioned interchange artifacts under interchange/.
#
# Regenerates:
#   interchange/config.v1.json
#   interchange/levels/<name>.v1.json
#   interchange/files.sha256
#
# Run from anywhere; paths resolve relative to this script.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ref_dir="$repo_root/reference/peggle_evolved"
pin="$repo_root/reference/PIN.md"
tools="$repo_root/tools"
interchange="${INTERCHANGE_DIR:-$repo_root/interchange}"
levels_dir="$interchange/levels"

if [[ ! -d "$ref_dir" ]]; then
  echo "ERROR: missing vendored reference at $ref_dir" >&2
  exit 1
fi

revision="$(sed -n 's/.*Revision (full) | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
tree="$(sed -n 's/.*Tree hash | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
if [[ -z "$revision" || -z "$tree" ]]; then
  echo "ERROR: cannot read revision/tree from $pin" >&2
  exit 1
fi
config_sha="$(sha256sum "$ref_dir/src/config.lua" | awk '{print $1}')"

mkdir -p "$levels_dir" "$interchange/previews"

mapfile -t levels < <(luajit "$tools/export_level.lua" --reference "$ref_dir" --list --static | sort)
if [[ ${#levels[@]} -eq 0 ]]; then
  echo "ERROR: no static levels found in $ref_dir/src/levels" >&2
  exit 1
fi

echo "reference=$revision config_sha256=$config_sha"
echo "static levels: ${levels[*]}"

for level in "${levels[@]}"; do
  luajit "$tools/export_level.lua" \
    --reference "$ref_dir" \
    --level "$level" \
    --out "$levels_dir/$level.v1.json" \
    --check \
    --revision "$revision" \
    --tree "$tree" \
    --config-sha256 "$config_sha"
done

luajit "$tools/export_config.lua" \
  --reference "$ref_dir" \
  --out "$interchange/config.v1.json" \
  --check \
  --source-sha256 "$config_sha"

python3 "$repo_root/scripts/render_level_svg.py" \
  --all \
  --interchange "$interchange" \
  --config "$interchange/config.v1.json"

# Manifest over every generated interchange file except the manifest itself.
(
  cd "$interchange"
  find . -type f ! -name 'files.sha256' -print0 \
    | sort -z \
    | xargs -0 sha256sum
) > "$interchange/files.sha256"
sort -k2 -o "$interchange/files.sha256" "$interchange/files.sha256"

echo "wrote $(wc -l < "$interchange/files.sha256") interchange artifacts"
