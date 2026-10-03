# 0002-multiball-fever-reset.md

## Symptom
- Catching a ball in the fever bucket prematurely resets the level. Any other active multiballs are immediately destroyed without being able to fall and score points.
- Fever catch points were being double-counted in normal gameplay mode.

## Root Cause
- The `GameState:_onFeverCatch` callback and `mode.lua` benchmark equivalent were unconditionally calling `engine:setupLevel()` and `engine:resetTurn()` immediately upon a ball entering the fever bucket. This reset the active ball list.
- Because `setupLevel()` wiped the pegs, `allRedCleared` evaluated to false in `_endTurn()`, preventing the game from registering a win state. 
- In `game.lua`, `eng.bonusScore = eng.bonusScore + value` was being called inside `_onFeverCatch`, but the `core.lua` engine also added the `value` to `bonusScore` automatically, resulting in double points.

## Solution
- Removed the manual `eng.bonusScore` addition and level resetting logic from `_onFeverCatch` in `src/states/game.lua`. The engine now allows all active multiballs to fall into the fever buckets naturally, and relies on `GameState:_endTurn()` to handle the win state cleanly once the active ball count reaches 0.
- In `src/bench/mode.lua`, the level reset logic was moved to `onTurnEnd()`. When `eng.isFever` is true, the script waits for all balls to be fully depleted before reloading the level for the next iteration.