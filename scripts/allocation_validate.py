#!/usr/bin/env python3
"""Run baseline/candidate allocation qualification on deathstar only."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text(), parse_int=lambda s: -0.0 if s == "-0" else int(s))


def exact(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(exact(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(exact(x, y) for x, y in zip(a, b))
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if isinstance(a, bool) or isinstance(b, bool):
            return type(a) is type(b) and a == b
        return struct.pack('>d', a) == struct.pack('>d', b)
    return type(a) is type(b) and a == b


def source_manifest(workspace):
    paths = sorted((workspace / "julia/PeggleSim").rglob("*.jl"))
    paths += sorted((workspace / "julia/PeggleSim").glob("*.toml"))
    return {str(p.relative_to(workspace)): sha(p) for p in paths}


def main():
    if socket.gethostname().split('.')[0] != 'deathstar':
        raise SystemExit('Run on deathstar')
    root = Path(sys.argv[1]).resolve()
    base, candidate = root / 'baseline', root / 'candidate'
    out = root / 'qualification'
    out.mkdir(exist_ok=True)
    env = dict(os.environ, JULIA_NUM_THREADS='1', JULIA_NUM_PRECOMPILE_TASKS='1',
               JULIA_PKG_PRECOMPILE_AUTO='0', OPENBLAS_NUM_THREADS='1',
               OMP_NUM_THREADS='1', PEGGLE_MATH_BACKEND='system_libm')
    julia = '/home/picazio/.julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia'
    report = {'format': 'peggle.allocation_qualification.v1',
              'generated_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'baseline_commit': '6d09319c33162d7fb9957cf096ef29c3478c471e',
              'candidate_base_commit': '6d09319c33162d7fb9957cf096ef29c3478c471e',
              'candidate_kind': 'uncommitted worktree snapshot',
              'host': socket.gethostname(), 'julia_executable': julia,
              'environment': {k: env[k] for k in ('JULIA_NUM_THREADS', 'JULIA_NUM_PRECOMPILE_TASKS',
                  'JULIA_PKG_PRECOMPILE_AUTO', 'OPENBLAS_NUM_THREADS', 'OMP_NUM_THREADS', 'PEGGLE_MATH_BACKEND')},
              'commands': [], 'source_manifests': {}, 'traces': {}, 'sweeps': {}}
    failures = []

    def run(args, workspace, label):
        log = out / (label + '.log')
        with log.open('w') as handle:
            result = subprocess.run(args, cwd=workspace, env=env, stdout=handle,
                                    stderr=subprocess.STDOUT, timeout=1800)
        report['commands'].append({'argv': list(map(str, args)), 'cwd': str(workspace),
                                   'exit_code': result.returncode, 'log': log.name})
        if result.returncode:
            failures.append(label)
        print(label, result.returncode, flush=True)
        return result.returncode

    def jl(threads=1):
        return ['nice', '-n', '10', 'timeout', '900', julia, '--startup-file=no',
                '--gcthreads=1', '-t', f'{threads},0', '--project=julia/PeggleSim']

    try:
        for name, workspace in [('baseline', base), ('candidate', candidate)]:
            report['source_manifests'][name] = source_manifest(workspace)
            run(['make', 'verify'], workspace, name + '-verify-before')
        discovered = sorted(p.name for p in (candidate / 'julia/PeggleSim/test').glob('test_*.jl'))
        required = {'test_shot_scratch.jl', 'test_contact_payloads.jl'}
        assert required.issubset(discovered)
        report['candidate_discovered_test_files'] = discovered
        # Pkg.test uses a bounds-checking cache distinct from ordinary measurement.
        run(jl() + ['--check-bounds=yes', '--depwarn=yes', '-e',
                    'using Pkg; Pkg.precompile(); using Test, PeggleSim'], candidate, 'candidate-test-precompile')
        run(jl() + ['-e', 'using Pkg; Pkg.test(; julia_args=["--startup-file=no", "--threads=1,0", "--gcthreads=1"])'],
            candidate, 'candidate-tests')
        log = (out / 'candidate-tests.log').read_text()
        counts = re.search(r'PeggleSim\s*\|\s*(\d+)\s+(\d+)\s+', log)
        report['candidate_package_tests'] = {'passed': int(counts[1]) if counts else None,
                                             'total': int(counts[2]) if counts else None}
        run(jl() + ['julia/PeggleSim/bin/parity_emit.jl', '--out', str(out / 'candidate-parity.json'),
                    '--label', 'deathstar-allocation-candidate'], candidate, 'candidate-parity')
        bp, cp = load(base / 'tmp/allocation/parity.json'), load(out / 'candidate-parity.json')
        report['parity'] = {'baseline': bp, 'candidate': cp,
            'authoritative_bit_identical': exact(bp['authoritative'], cp['authoritative']),
            'identity_different_keys': [k for k in set(bp['identity']) | set(cp['identity'])
                                        if not exact(bp['identity'].get(k), cp['identity'].get(k))]}
        if not report['parity']['authoritative_bit_identical']:
            failures.append('authoritative-parity')

        fixtures = sorted((base / 'fixtures/mustache/expected').glob('*.json'))
        assert len(fixtures) == 5
        for name, workspace in [('baseline', base), ('candidate', candidate)]:
            for mode in ('plain', 'snapshots'):
                target = out / name / mode
                (target / 'traces').mkdir(parents=True, exist_ok=True)
                (target / 'expected').mkdir(exist_ok=True)
                for fixture in fixtures:
                    fx = load(fixture)
                    cmd = jl() + ['julia/PeggleSim/bin/shot_bench.jl', '--fixture', fx['id'],
                        '--level', 'fixtures/mustache/artifact/mustache.v1.json',
                        '--config', 'fixtures/mustache/config.dev.v1.json',
                        '--aim', str(fx['action']['aim_index']), '--category', fx['category'],
                        '--trace-out', str(target / 'traces' / (fx['id'] + '.jsonl')),
                        '--expected-out', str(target / 'expected' / fixture.name)]
                    if mode == 'snapshots':
                        cmd.append('--snapshots')
                    run(cmd, workspace, f'{name}-{mode}-{fx["id"]}')

        for mode in ('plain', 'snapshots'):
            left, right = out / 'baseline' / mode, out / 'candidate' / mode
            result = out / f'trace-{mode}-comparison.json'
            run(['python3', 'tools/compare_traces.py', '--control',
                 '--left-traces', str(left / 'traces'), '--left-expected', str(left / 'expected'),
                 '--right-traces', str(right / 'traces'), '--right-expected', str(right / 'expected'),
                 '--out', str(result)], candidate, f'trace-{mode}-comparison')
            report['traces'][mode] = {'comparison': load(result), 'byte_identity': {}}
            for fixture in fixtures:
                path = 'traces/' + fixture.stem + '.jsonl'
                a, b = sha(left / path), sha(right / path)
                identical = a == b
                report['traces'][mode]['byte_identity'][fixture.stem] = {
                    'baseline_sha256': a, 'candidate_sha256': b, 'identical': identical}
                if not identical:
                    failures.append(mode + '-trace-bytes-' + fixture.stem)

        for name, workspace in [('baseline', base), ('candidate', candidate)]:
            result = out / f'{name}-goldens-comparison.json'
            target = out / name / 'plain'
            run(['python3', 'tools/compare_traces.py', '--require-identical',
                 '--left-traces', 'fixtures/mustache/traces', '--left-expected', 'fixtures/mustache/expected',
                 '--right-traces', str(target / 'traces'), '--right-expected', str(target / 'expected'),
                 '--out', str(result)], workspace, name + '-goldens-comparison')
            report['traces'][name + '_goldens'] = {'comparison': load(result), 'byte_identity': {}}
            for fixture in fixtures:
                trace = fixture.stem + '.jsonl'
                gold, actual = workspace / 'fixtures/mustache/traces' / trace, target / 'traces' / trace
                report['traces'][name + '_goldens']['byte_identity'][fixture.stem] = {
                    'golden_sha256': sha(gold), 'actual_sha256': sha(actual), 'identical': sha(gold) == sha(actual)}

        for name, workspace in [('baseline', base), ('candidate', candidate)]:
            report['sweeps'][name] = {}
            for threads in (1, 2, 4):
                prefix = out / f'{name}-stride20-t{threads}'
                run(jl(threads) + ['julia/PeggleSim/bin/shot_bench.jl', '--sweep',
                    '--level', 'fixtures/mustache/artifact/mustache.v1.json',
                    '--config', 'fixtures/mustache/config.dev.v1.json', '--stride', '20',
                    '--threads', str(threads), '--verify-serial', '--out', str(prefix) + '.jsonl',
                    '--summary', str(prefix) + '.json'], workspace, prefix.name)
                report['sweeps'][name][str(threads)] = load(Path(str(prefix) + '.json'))
            hashes = [sha(out / f'{name}-stride20-t{t}.jsonl') for t in (1, 2, 4)]
            report['sweeps'][name]['cross_thread_identical'] = len(set(hashes)) == 1
            report['sweeps'][name]['rows_sha256'] = hashes[0]
            if len(set(hashes)) != 1:
                failures.append(name + '-cross-thread-sweep')
        identical = report['sweeps']['baseline']['rows_sha256'] == report['sweeps']['candidate']['rows_sha256']
        report['sweeps']['baseline_candidate_identical'] = identical
        if not identical:
            failures.append('baseline-candidate-sweep')

        run(['bash', 'scripts/allocation_remote.sh', str(candidate), 'measure', 'candidate',
             str(base / 'tmp/allocation/measurement.json')], candidate, 'candidate-measurement')
        report['measurements'] = {'baseline': load(base / 'tmp/allocation/measurement.json'),
                                  'candidate': load(candidate / 'tmp/allocation/measurement.json')}
    except Exception as exc:
        failures.append(repr(exc))
        raise
    finally:
        for name, workspace in [('baseline', base), ('candidate', candidate)]:
            run(['make', 'verify'], workspace, name + '-verify-after')
            if source_manifest(workspace) != report['source_manifests'][name]:
                failures.append(name + '-source-changed-during-run')
        report['failures'] = failures
        report['passed'] = not failures
        (out / 'allocation-qualification.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
