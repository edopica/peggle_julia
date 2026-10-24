#!/usr/bin/env python3
"""Audit saved 1v1 campaign histories, identity, inputs and scaling metrics."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('report', type=Path)
p.add_argument('--out', type=Path)
a = p.parse_args()
r = json.loads(a.report.read_text())
config = json.loads((ROOT/r['options']['config']).read_text())['values']
size = int(r['options']['sector-size'])
epsilon = int(r['options']['epsilon'])
last = r['candidate_count']-1
expected = None
checked = 0
for trial in r['trials']:
    run = json.loads((ROOT/trial['history']).read_text())
    if expected is None:
        expected = run['games']
    assert run['games'] == expected, trial['history']
    assert trial['completed_matches'] == sum(g['completed'] for g in run['games'])
    assert trial['candidates'] == sum(t['candidates'] for t in run['timings'])
    for g in run['games']:
        assert g['mode']=='1v1'
        scores = [0,0]
        balls = [config['starting_balls']]*2
        previous_reds = 0
        previous_catches = 0
        expected_player = 1
        settled = 0
        for d in g['decisions']:
            if 'incomplete_candidates' in d:
                assert not g['completed'] and g['termination_reason']=='candidate_step_limit'
                continue
            checked += 1
            assert d['player']==expected_player
            sectors=d['sectors']
            coverage=[i for s in sectors for i in range(s['first'],s['last']+1)]
            assert coverage==list(range(last+1))
            assert all(s['first']==j*size and s['last']==min((j+1)*size-1,last) for j,s in enumerate(sectors))
            assert all(s['indices'] and all(s['first']<=i<=s['last'] for i in s['indices']) for s in sectors)
            median=statistics.median(s['score'] for s in sectors)
            assert median==d['median']
            eligible=[s['sector'] for s in sectors if s['score']>=median]
            assert eligible==d['eligible_sectors'] and d['selected_sector'] in eligible
            assert d['intended_index'] in sectors[d['selected_sector']-1]['indices']
            assert -epsilon<=d['offset']<=epsilon
            assert d['executed_index']==d['intended_index']+d['offset'] and 0<=d['executed_index']<=last
            assert sum(d['style_counts'].values())==d['shot']['style_total']
            assert d['shot']['score']==d['shot']['peg_score']+d['shot']['bonus']+d['shot']['style_points']
            actor=d['player']-1
            balls[actor]-=1
            assert balls==d['player_balls']
            if not d['shot']['completed']:
                assert not g['completed'] and g['termination_reason']=='actual_step_limit'
                continue
            settled+=1
            s=d['settlement']
            red=d['shot']['reds_hit']>previous_reds
            assert red==s['hit_red']
            before=scores[actor]
            penalty=0 if red else before//4
            credited=d['shot']['score'] if red else 0
            scores[actor]+=credited-penalty
            assert s['penalty']==penalty and s['credited_score']==credited
            assert s['score_before']==before and s['score_after']==scores[actor]
            assert s['score_delta']==credited-penalty and d['player_scores']==scores
            catches=d['shared_bucket_hits']
            assert catches>=previous_catches
            bonus=config['bucket_incremental_base']*sum(range(previous_catches+1,catches+1))
            assert d['shot']['bonus']>=bonus
            if not d['shot']['is_fever']:
                assert d['shot']['bonus']==bonus
            if s['reason']=='continue':
                expected_player=3-d['player']
                if balls[expected_player-1]<=0:
                    expected_player=d['player']
                assert d['next_player']==expected_player
            else:
                assert d['next_player'] is None
            previous_reds=d['shot']['reds_hit']
            previous_catches=catches
        assert g['player_scores']==scores and g['player_balls']==balls and g['final_score']==scores
        assert g['shared_bucket_hits']==previous_catches
        assert g['player_turns']==[sum(d.get('player')==i and 'shot' in d for d in g['decisions']) for i in (1,2)]
        assert g['turns']==sum('shot' in d for d in g['decisions'])
        if g['completed']:
            assert g['termination_reason'] in ('all_red_cleared','balls_exhausted')
            assert g['winner']==(1 if scores[0]>scores[1] else 2 if scores[1]>scores[0] else 0)
            if g['termination_reason']=='all_red_cleared':
                assert g['decisions'][-1]['remaining_red_pegs']==0
            else:
                assert balls==[0,0]
assert r['source_sha256'], 'report must include runtime source hashes'
for path,want in r['source_sha256'].items():
    assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==want,path
for option,key in [('level','level_sha256'),('config','config_sha256')]:
    assert hashlib.sha256((ROOT/r['options'][option]).read_bytes()).hexdigest()==r[key]
assert len({t['gameplay_sha256'] for t in r['trials']})==1
seeds=[seed for g in expected for seed in g['bot_seeds']]
assert len(seeds)==len(set(seeds))
base=statistics.median(t['wall_seconds'] for t in r['trials'] if t['workers']==1)
scaling=[]
for workers in r['worker_counts']:
    trials=[t for t in r['trials'] if t['workers']==workers]
    wall=statistics.median(t['wall_seconds'] for t in trials)
    scaling.append({'workers':workers,'median_wall_seconds':wall,
                    'median_completed_matches_per_hour':statistics.median(t['completed_matches_per_hour'] for t in trials),
                    'median_candidates_per_second':statistics.median(t['candidates_per_second'] for t in trials),
                    'speedup':base/wall,'parallel_efficiency':base/wall/workers})
summary={'identity_verified':True,'decisions_audited':checked,'measured_campaigns':len(r['trials']),
         'measured_candidates':sum(t['candidates'] for t in r['trials']),
         'completed_matches':sum(t['completed_matches'] for t in r['trials']),
         'source_and_input_hashes_verified':True,'scaling':scaling}
text=json.dumps(summary,indent=2)+'\n'
if a.out:
    a.out.parent.mkdir(parents=True,exist_ok=True)
    a.out.write_text(text)
print(text,end='')
