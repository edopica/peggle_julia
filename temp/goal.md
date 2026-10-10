The goal is to create a julia clone of the game for massive simulations.

peggle needs to have amazing levels, but in order to get them it's not enough to design a nice shape on a screen, you also need to play them and see if they create funny situations. That's when the julia clone comes in.

### Goals of the port
1. generator: we are gonna create procedural content.
2. tester: we are gonna simulate games, a lot of games, on each level.
3. parser: after accumulating level data, we are gonna do all sorts of analysis on it, by measuring score distributions, information theory. and whatever we can come up with.

## My greatest concern
The whole point of porting to julia is to have a *fast* simulator, otherwise I would have sticked with lua. I will briefly describe you the simulation process so you can understand what we need to optimize.

### Bots
Simulations happen with bots. A bot will scan the whole set of possible shots and choose one based on shot values (such as score, style points) and a bot config (skill level, bot-specific strategies, ...).

Thus the main performance issue is to simulate and profile the set of possible shots as fast as possible. Fortunately it's an embarrassingly parallel problem.

## Other concernces
I realized that, even if the julia clone runs headless, it still would be nice to have a way to visualize what it's doing. I don't know if this should be addressed on the port itself (julia has raylib library) or maybe we can just export games and look at them through the lua version. Even more importantly, since the port has the goal of generating levels, I need at least to be able to look at a level preview.

math parity is another aspect to which I want to dedicate some time as well. see the dedicated document in this folder for more details.
However I would defer device device-specific solutions since I plan to run the julia version on various servers I have access to.
