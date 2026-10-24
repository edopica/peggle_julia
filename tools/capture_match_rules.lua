-- Run the saved Lua GameState methods directly with a minimal engine double.
-- No physics expectations are fabricated: this captures only match-layer rules.
-- Usage: luajit tools/capture_match_rules.lua > fixtures/matches/rules.v1.json
package.path = 'tools/?.lua;' .. package.path
local Config = dofile('campaigns/ribbon/config.source.lua')
package.loaded['src.config'] = Config
for _,name in ipairs({'src.systems.screen','src.systems.perf','src.states',
    'src.engine.core','src.cli_options','src.systems.gameplay_trace_exporter',
    'src.systems.replay_library'}) do package.loaded[name] = {} end
package.loaded['src.systems.level_manager'] = {virtual_width=700, virtual_height=600}
local Game = dofile('campaigns/ribbon/game.source.lua')
local cases = {
    {name='red_scores_and_alternates', scores={1003,2000}, balls={2,2}, player=1, score=200, red=true},
    {name='no_red_discards_catches_then_floors_penalty', scores={1003,2000}, balls={2,2}, player=1, score=200, catches=2},
    {name='shared_catch_counter_crosses_players', scores={1003,2000}, balls={2,2}, player=2, score=100, red=true, catches=1, shared=2},
    {name='skip_exhausted_opponent', scores={1003,2000}, balls={2,0}, player=1, score=200, red=true},
    {name='both_exhausted', scores={1003,1000}, balls={1,0}, player=1, score=200, red=true},
    {name='red_clear_uses_scores_not_last_player', scores={100,10000}, balls={2,2}, player=1, score=500, red=true, clear=true},
    {name='draw', scores={0,0}, balls={1,0}, player=1, score=0},
    {name='no_red_zero_bank', scores={0,0}, balls={2,2}, player=1, score=500},
    {name='solo_free_balls', mode='solo', scores={100,0}, balls={2,2}, player=1, score=200, red=true, catches=2},
}
local rows={}
for _,c in ipairs(cases) do
    local g=setmetatable({mode=c.mode or '1v1', current_player_index=c.player,
        players={{score=c.scores[1],balls=c.balls[1]},{score=c.scores[2],balls=c.balls[2]}},
        shared_bucket_hits=c.shared or 0, game_over=false, style_popups={}}, {__index=Game})
    local resets=0
    local eng={bonusScore=0, turnPegsHit=c.red and {{type='red'}} or {},
        pegs=c.clear and {} or {{type='red',hit=false}},
        getTurnScore=function(e) return c.score+e.bonusScore end,
        resetTurn=function() resets=resets+1 end}
    g.engine=eng
    assert(g:_onLaunch(eng))
    for _=1,c.catches or 0 do g:_onBucketCatch(eng) end
    local shot_score=eng:getTurnScore()
    g:_endTurn(eng)
    rows[#rows+1]={input=c,expected={scores={g.players[1].score,g.players[2].score},
        balls={g.players[1].balls,g.players[2].balls}, player=g.current_player_index,
        shared=g.shared_bucket_hits, bonus=eng.bonusScore, shot_score=shot_score,
        completed=g.game_over, winner=g.winner, resets=resets}}
end
print(require('canonical_json').encode({format='peggle.match-rules',version=1,cases=rows}))
