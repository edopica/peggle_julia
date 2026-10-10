# CORE-MATH-era parity census (travel copy)

`math_census.v1.json` is the experimental CORE-MATH-era parity census
fixture. It reuses the exact historical input corpus (15,794 cases) but
records the expected values computed through the Lua dev tree with
`PEGGLE_MATH_BACKEND=core_math`, so it differs from the historical
`fixtures/math_census/math_census.v1.json` in exactly 100 expected values
(the recorded WP-D backend differences: 90 NaN sign/payload, 10 finite).
The historical fixtures remain untouched and are never read as expectations
by this path.

| Field | Value |
| --- | --- |
| Size | 670,689 bytes |
| SHA-256 | `075130e0ce57043e9582bc16272b6f633ae1584b7f900a13ee4223182d62b9f2` |

This copy lives under `results/` (tracked), unlike the scratch original
under `tmp/core-math/parity/` (gitignored), so it travels with the
repository to the macOS and Windows qualification machines. It is the
canonical `--census` input for cross-machine parity manifests: both hosts
must use this exact file, and `PeggleSim.parity_manifest` records its
effective repository-relative path and SHA-256 in
`identity.prerequisites` (`census_fixture_path`,
`census_fixture_sha256`). `scripts/compare_parity.sh` rejects manifests
whose recorded census differs (exit 3, `INCOMPATIBLE`), so a clean
cross-machine comparison requires byte-identical census inputs.

The scratch original is regenerated with:

```bash
make wpd-parity
# or directly:
scripts/capture_wpd_parity_census.sh
```

Both write `tmp/core-math/parity/math_census.v1.json` and require the
sibling `../peggle_evolved` dev tree, LuaJIT, and the Linux CORE-MATH
artifact. To refresh this tracked copy, copy that file here byte-for-byte
and confirm the SHA-256:

```bash
cp tmp/core-math/parity/math_census.v1.json results/core-math/parity/
sha256sum -c <<'EOF'
075130e0ce57043e9582bc16272b6f633ae1584b7f900a13ee4223182d62b9f2  results/core-math/parity/math_census.v1.json
EOF
```

The operational runbook for collecting the second-host/second-OS evidence
is `wiki/context/cross-platform-qualification.md`.
