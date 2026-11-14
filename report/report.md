# How Good Is a Peggle Level? A Guided Tour of the Level Evaluation Model

Date: 2026-11-10. Scope: the five-pillar level evaluation model for Peggle Evolved, its profiler `scripts/profile_level.jl`, and the measured profiles of five levels.

## 0. About this report

### 0.1 What this report is

An earlier work session built a mathematical model that gives a Peggle level a number between 0 and 1. The number is the **Level Quality Index (LQI)**. A Julia script computes it from thousands of simulated shots and a few simulated 1v1 matches.

The model borrows ideas from six fields: information theory, chaos theory, the study of skill and luck, game theory, compression, and search-based level generation. The original notes are correct but dense. They assume that you know all six fields already.

This report explains the same model from the start. It adds no new results. Every number comes from `results/analysis/level_evaluation_profiles.json` or from the code in `scripts/profile_level.jl`.

### 0.2 The question

The model answers one question: **how good is a level, and why?**

The "why" part matters more than the number. The model splits "good" into five separate parts, the five pillars. If a level scores badly, the pillars tell you where the problem is. For example, a level can give the player good control of the ball but give the ball nothing interesting to do.

### 0.3 How to read this report

Read Section 1 if you do not know how Peggle Evolved plays. Read Section 2 next. It introduces each mathematical tool with a picture in your head first, then a Peggle example, then the formula. You can skip a formula and still follow the rest. Sections 3 and 4 use the tools from Section 2. Section 6 is a glossary. If a word confuses you, look there.

| If you want to know | Read |
|---|---|
| How a shot and a 1v1 match work | Section 1 |
| What entropy, mutual information and the other tools mean | Section 2 |
| How the model turns simulations into one number | Section 3 |
| What the model says about the five real levels | Section 4 |
| What the model does not see, and which numbers are guesses | Section 5 |
| A short meaning for each special term | Section 6 |
| The papers behind the ideas | Section 7 |

### 0.4 Labels in this report

Some claims come from measurement. Others come from a choice that a person made. The report marks the difference with these labels:

- **[MEASURED]**: the profiler computed this number from simulations.
- **[CODE]**: the code does this. The label points to how, not to a measured result.
- **[HAND-SET]**: a person chose this number, for example a weight or a target. No measurement fixed it.
- **[THEORY]**: the idea comes from a paper or from physics. The profiler does not measure it directly.
- **[PROPOSED]**: the notes describe this, but the code does not use it yet.

### 0.5 Words in this report

The report uses each word with one meaning:

- **level**: the design. The list of pegs, shapes and lines, as an artist made it.
- **board**: the pegs that are still on screen at one moment of a match. The board changes as players clear pegs.
- **shot**: one launch of the ball, until every ball has left the screen.
- **aim index**: a whole number from 0 to 1800 that selects the launch angle. One step is 0.1°.
- **points**: the in-game score that a player earns.
- **rating**: a number from 0 to 1 that the model gives. Pillar ratings and the LQI are ratings.
- **metric**: one measured quantity, for example "mean pegs hit per shot".
- **outcome**: a short label that describes what a shot did. Section 2 explains the different outcome labels.
- **bot**: a computer player. Its **policy** is the rule that it uses to select a shot.

## 1. The game in five minutes

### 1.1 One shot

A launcher sits at the top center of the screen. The player selects an angle and fires one ball. Gravity pulls the ball down. The ball bounces off pegs and walls. Each peg that the ball touches lights up and gives points. When the ball leaves the bottom of the screen, the shot ends. The game then removes the lit pegs.

The game has 1801 possible angles. They cover 180°, so neighbouring angles differ by 0.1°. The model calls each angle an **aim index**, from 0 to 1800.

> **Intuition:** 0.1° is very small. On a 1200-pixel-wide screen, it moves the ball about 1 to 2 pixels after its first 1000 pixels of flight. A human cannot aim this precisely. This fact is the reason that the model adds "aim noise" in Section 2.3.

### 1.2 Pegs and slides

Pegs have colors:

- **Red** pegs are the targets. They are worth 100 points each. When all red pegs are gone, the match ends.
- **Blue** pegs are worth 10 points.
- **Green** pegs spawn extra balls.
- **Purple** pegs are worth 500 points.

Pegs also have shapes: circles, rectangles and **annular** pegs. An annular peg is a short piece of a curved band.

Pegs can belong to a **line**. If the line has no gap between its pegs, the ball can roll along it. The game calls this a **slide**. In the model, a slide is also called a **waveguide**, a word from physics for a channel that guides a wave. Section 2.6 explains why that word fits.

### 1.3 Points

The points for one shot grow faster than the number of pegs. The game adds the value of each peg, multiplies by a red-peg multiplier, and then multiplies by the number of pegs hit. So a shot that hits twice as many pegs gives about four times the points.

The **multiplier** rises as the players clear more red pegs. When all red pegs are gone, the multiplier is ×100. This is called **fever**.

The game also gives **style** bonuses. Examples are a long slide along a line, a "long shot" across the screen, or an "off the wall" bounce. The model tracks six styles: `slide`, `long_shot`, `super_long_shot`, `double_long_shot`, `off_the_wall` and `lucky_bounce`.

A **bucket** moves left and right at the bottom. If the ball falls into it, the player gets bonus points.

### 1.4 The 1v1 match

The model studies the 1v1 mode. Two players share one board and take turns. Each player starts with 10 balls. Two rules make this mode tactical:

1. **The red-peg penalty.** If a shot hits no red peg, the shot earns nothing. Also, the player loses 25% of the points in the bank.
2. **The shared bucket.** Each bucket catch is worth more than the last one: 2,500 points, then 5,000, then 7,500, and so on.

The match ends when all red pegs are gone, or when both players have no balls left.

### 1.5 The five levels

The profiler measured five levels. They are very different, which makes them a good test set.

| Level | Short description | Pegs | Red pegs | Slide fraction |
|---|---|---|---|---|
| `ribbon_waves` | 5 curved slide ribbons plus 53 circle pegs. The team considers it an enjoyable reference level. | 133 | 25 | 0.60 |
| `mustache` | 3 identical, mirror-symmetric "mustache" shapes, stacked vertically. | 99 | 16 | 0.73 |
| `circle_level` | 25 circle pegs and no slides. A small grid. | 25 | 10 | 0.00 |
| `squiggly_circle` | 192 annular pegs in one closed, wavy ring. | 192 | 10 | 1.00 |
| `slide` | 3 slides. A test level for style shots. It has no red pegs. | 73 | 0 | 0.99 |

[FIGURE: Five small level thumbnails side by side, one per level, from the SVG previews that `make export` produces. Label each with its name, peg count and slide fraction from the table above.]

## 2. The toolbox

This section introduces each tool before the model uses it. Each part has the same order: the intuition, a Peggle example, and then the formula. Every symbol in a formula has a plain explanation under it.

### 2.1 Probability and bits

A **probability** is a number from 0 to 1 that says how often something happens. If 450 of the 1801 aim indices hit a red peg, the probability that a random aim hits red is $450/1801 \approx 0.25$.

A **bit** is a unit of information. One bit is the answer to one fair yes-or-no question. If you must guess a number from 1 to 8, you need three yes-or-no questions. So the answer holds 3 bits. In general, a choice among $n$ equal options holds $\log_2 n$ bits.

> **Example:** Selecting one aim index out of 1801 holds $\log_2 1801 \approx 10.8$ bits. This is the most information that one shot can carry.

### 2.2 Entropy: how many different things can happen?

**Intuition.** Entropy measures surprise, or variety. A coin that always lands on heads has zero entropy. You learn nothing from a throw. A fair coin has 1 bit. A fair six-sided die has about 2.6 bits.

**Peggle example.** Fire a shot at every one of the 1801 aim indices. Write down which set of pegs each shot hits. On `ribbon_waves`, 1797 of the 1801 shots hit a different set of pegs. The entropy of the hit set is 10.81 bits. This is almost the maximum of 10.81 bits from Section 2.1. Nearly every angle gives its own result. [MEASURED]

**Formula.** The Shannon entropy of an outcome $O$ is

$$H(O) = -\sum_{o} P(o)\,\log_2 P(o)$$

- $O$ is the outcome of a shot. It is a label, for example "hit pegs 4, 7 and 12".
- $o$ is one possible value of that label.
- $P(o)$ is the fraction of shots that give the value $o$.
- The sum goes over all values that occur. The minus sign makes the result positive.
- The unit is bits, because the logarithm has base 2.

> **Watch out:** High entropy alone is not good. A pinball machine with random results also has high entropy. Variety is only half of the story. The other half is control, in Section 2.3.

The paper behind this tool is Shannon (1948), *A Mathematical Theory of Communication*.

### 2.3 Noisy aim and mutual information: how much does the player control?

**The problem.** The simulator is exactly deterministic. The same aim index always gives the same shot, to the last bit. If the player could select the aim index perfectly, the aim would decide everything. Then every level would look "fully controllable", even a chaotic one. That answer is useless.

**The fix.** Real players are not perfect. The model adds **aim noise**. The player intends aim index $a$. The game fires a slightly different index $\tilde a$, picked at random from the $2\sigma+1$ neighbours around $a$. For example, with $\sigma = 2$, the intended index 900 can become 898, 899, 900, 901 or 902, each with the same chance. One step is 0.1°, so $\sigma = 2$ means $\pm 0.2°$.

[FIGURE: The "noisy aim channel". Left: a box "intended aim a". Arrow labeled "hand / mouse noise, ±σ steps" to a box "fired aim ã". Arrow labeled "deterministic physics" to a box "outcome O". Under the first arrow, a small bar chart: five equal bars at a−2 … a+2, each 1/5 high, labeled "σ = 2".]

Now we can ask a fair question. If I know what the player intended, how much do I know about the outcome?

**Intuition.** Picture the five neighbours of an intended aim. If all five give the same outcome, the noise does not matter. The player is in control. If all five give different outcomes, the player cannot tell which one will happen. The result is luck.

**Mutual information** measures this. It is the variety of outcomes, minus the confusion that the noise adds.

$$I_\sigma(A;O) = H(O) - H_\sigma(O \mid A)$$

- $A$ is the intended aim index.
- $O$ is the outcome label.
- $H(O)$ is the entropy of the outcome over all shots, as in Section 2.2.
- $H_\sigma(O \mid A)$ is the **conditional entropy**, also called **equivocation**. It is the uncertainty that remains after you know the intended aim. The model computes it for each intended aim from its $2\sigma+1$ neighbours, then takes the average.
- $\sigma$ is the noise width in aim steps.
- $I_\sigma(A;O)$ is in bits. It is the amount of outcome variety that the player really controls.

> **Example:** With $\sigma = 2$, an aim has 5 neighbours. If they give 5 different outcomes, the confusion for that aim is $\log_2 5 \approx 2.3$ bits. If they all give one outcome, the confusion is 0 bits.

From mutual information, the model gets one more ratio, the **controllability**:

$$\mathcal{C}_\sigma = \frac{I_\sigma(A;O)}{H(O)}$$

It is a number from 0 to 1. It says what fraction of the variety is under the player's control. 1 means pure skill. 0 means pure luck.

The profiler computes these values for five noise widths: $\sigma = 1, 2, 5, 10, 20$. The LQI uses $\sigma = 2$. [CODE]

### 2.4 The outcome label: how detailed must it be?

Mutual information depends on what you call "the outcome". The model uses four labels. [CODE]

- **Hit set**: the exact set of pegs hit. This label is very fine. Two shots that share 14 of 15 pegs still count as different.
- **Score tier**: the points of the shot, sorted into 16 brackets.
- **Tactical label**: did the shot hit red, did it reach the bucket, which styles it earned, and roughly how many pegs it hit.
- **Route label**: a coarse summary in five parts. Where on the screen the hit pegs are on average (a 4 × 4 grid). How many pegs, on a log scale from 0 to 5. Which quarter of the screen width the ball left from, or "bucket". Whether the shot earned any style. Whether it hit red.

The route label is the main one. It answers "where did the shot go, how much did it do, and was it useful", but it ignores single-peg details.

**Why a coarse label?** This idea comes from the **information bottleneck** of Tishby, Pereira and Bialek (2000). Their point is that a good summary keeps the information that matters and throws away the rest. For a player, "the ball went down the left ribbon and cleared a lot" matters. "It touched peg 87 and not peg 88" usually does not.

> **Key idea:** A fine label makes every level look chaotic. A coarse label makes every level look controllable. The route label sits between the two.

### 2.5 Empowerment: control for a smart player

**Intuition.** Mutual information in Section 2.3 assumes that the player picks every aim index equally often. Real players do not. A good player avoids angles that do nothing and uses the angles that work. **Empowerment** is the control that the best possible choice of angles can reach.

**Peggle example.** On `squiggly_circle`, 35% of aim indices hit no peg at all. A random player wastes many shots there. A smart player never aims there. Empowerment measures the control of that smart player.

**Formula.**

$$\mathfrak{E}_\sigma = \max_{p(a)} I_\sigma(A;O)$$

- $p(a)$ is how often the player selects aim $a$. It is a probability distribution over the 1801 aim indices.
- $\max_{p(a)}$ means: try every possible way to distribute the aims, and keep the highest mutual information.
- $\mathfrak{E}_\sigma$ is in bits.

In information theory, this maximum is the **channel capacity**. The profiler finds it with the **Blahut–Arimoto algorithm**. The algorithm starts with equal weights on all aims. Then it repeats one step: it gives more weight to aims whose outcomes stand out from the average. The profiler does this step 25 times. [CODE]

> **Watch out:** 25 rounds give a good estimate, not an exact answer. The code also takes the larger of this estimate and the plain mutual information, so empowerment is never lower than $I_\sigma$.

The papers are Salge, Glackin and Polani (2014), *Empowerment — An Introduction*, and two newer works: *The Geometry of Empowerment* (2026) and *Information-Theoretic Policy Pre-Training with Empowerment* (2025).

### 2.6 Chaos and billiards: why some shots stay controllable longer

**Intuition.** Push two balls on a pool table at almost the same angle. After one cushion, they are still close. On a table full of round posts, each post bends the two paths apart a bit more. After a few posts, the paths have nothing in common. This growth of small differences is **chaos**, or **sensitivity to initial conditions**.

**The Lyapunov exponent.** Physicists measure this growth with the **Lyapunov exponent** $\lambda$. If two paths start a tiny distance $\delta_0$ apart, after $k$ bounces they are about

$$\delta_k \approx \delta_0 \, e^{\lambda k}$$

apart.

- $\delta_0$ is the starting difference, for example 0.1° of aim.
- $k$ is the number of bounces.
- $\lambda$ is the average growth rate per bounce. If $\lambda > 0$, small errors grow fast. If $\lambda < 0$, nearby paths come together.

**Round pegs spread paths apart.** A round peg acts like a convex mirror. It makes a narrow beam of paths wider. The earlier notes estimate, from billiard theory, that one bounce off an isolated round peg makes an aim error about 14 times bigger. After three such bounces, a 0.1° error grows past 180°. The aim is forgotten. A grid of round pegs is called a **Galton board**, after the classic toy where balls fall through pins. [THEORY]

**Slides bring paths together.** A slide is different. When the ball lands on a slide, it loses most of its bounce and rolls along the line. Two balls that land on the same slide at slightly different points leave at almost the same place and speed. The slide "forgets" the small error, but it keeps the big decision: which slide the player hit. This is why the model calls slides waveguides. [THEORY]

[FIGURE: Two panels. Left panel "round peg spreads": a fan of three nearly parallel incoming paths hits a circle and leaves as a wide fan. Right panel "slide focuses": three nearly parallel paths land on a curved line of pegs at different points, roll along it, and leave its end as three almost identical paths. Caption: "Round pegs: λ > 0. Slides: λ < 0."]

> **Key idea:** A good level mixes both. Round pegs create branching and excitement. Slides carry the ball far without losing the player's intent.

**How the profiler sees this.** The profiler does not compute a Lyapunov exponent. Instead, it asks the information question at each step of the shot. It takes the first peg hit, the second, up to the fifteenth. For each position $k$, it computes the mutual information between the intended aim and the $k$-th peg. This gives a curve: **information versus hit number**. Section 3.4 uses it.

The papers are *Estimating Lyapunov Exponents in Billiards* (2019), *Dynamics of the No-Slip Galton Board* (2022), and van Beijeren, Dorfman, Posch and Dellago (2004) on the Lorentz gas, which is a model of a particle among fixed round scatterers.

### 2.7 Skill versus luck

**Intuition.** In chess, the better player almost always wins. In a coin toss, skill does not matter. Most games sit between the two. One way to place a game on this line is simple: let a stronger player meet a weaker one many times. Count how often the stronger one wins.

**Peggle example.** The profiler uses three bots:

- A **sector bot** with fine aim ($\pm 1$ step). It splits the 1801 aims into blocks of 100, finds the best shot in each block, and picks among the better half of the blocks.
- A **sloppy** sector bot with $\pm 10$ steps of aim noise ($\pm 1°$). Same rule, worse hands.
- A **random** bot. It fires at a random angle.

Fine aim against sloppy aim tests **motor skill**. The sector bot against the random bot tests **decision skill**. If the better bot wins almost every time, the level rewards skill. [CODE]

A fourth bot, the **tactical bot**, uses the expected value of Section 2.8. The profiler records its win rate against the sector bot, but the LQI does not use this number. [CODE]

The papers are Jerdee and Newman (2023), *Luck, skill, and depth of competition in games and social hierarchies*, and *Quantifying Skill and Chance: A Unified Framework for the Geometry of Games* (2025).

### 2.8 Game theory ideas used in 1v1

The model uses only a few game theory ideas. Each one is simple.

**Expected value with a penalty.** Each aim is like a lottery ticket. It hits red with some probability, and then it gives some points. If it misses red, the player loses 25% of the bank. The tactical bot computes, for each aim $a$:

$$U(a \mid B) = \text{average over the neighbours } \tilde a \text{ of } \begin{cases} S(\tilde a) & \text{if } \tilde a \text{ hits red} \\ -\lfloor 0.25\,B \rfloor & \text{if not} \end{cases}$$

- $B$ is the player's banked points before the shot.
- $S(\tilde a)$ is the points of the fired aim.
- $\lfloor \cdot \rfloor$ means "round down".
- The neighbours are the $2\varepsilon + 1$ aims that the noise can produce, where $\varepsilon$ is the bot's noise width.

> **Example:** Two shots. The safe shot hits red 95% of the time and gives 5,000 points. The risky shot hits red 60% of the time and gives 15,000 points. With an empty bank, the safe shot is worth $0.95 \times 5000 = 4750$ and the risky one $0.60 \times 15000 = 9000$. Go risky. With 100,000 points in the bank, a miss costs 25,000. Now the safe shot is worth $4750 - 0.05 \times 25000 = 3500$, and the risky shot $9000 - 0.40 \times 25000 = -1000$. Go safe.

So the best shot depends on the score. A good 1v1 level offers both kinds of shot, in many parts of the screen.

**Win-probability belief.** During a match, you can ask "what is the chance that Player 1 wins now?" Call this $p_t$ after turn $t$. The model estimates it from the score gap with an S-shaped curve, the **logistic function**:

$$p_t = \frac{1}{1 + e^{-(B_{1,t} - B_{2,t})/S_{\text{scale}}}}$$

- $B_{1,t}$ and $B_{2,t}$ are the banked points of Player 1 and Player 2 after turn $t$.
- $S_{\text{scale}}$ is a "large swing" size: one quarter of the median total points of a match, and at least 2,500. [HAND-SET]
- At the start, $p_0 = 0.5$. At the end, $p_T$ is 1 if Player 1 won, 0 if Player 2 won, 0.5 for a tie.

> **Example:** A gap of zero gives $p = 0.5$. A gap of one $S_{\text{scale}}$ gives $p \approx 0.73$. A gap of two gives $p \approx 0.88$.

**Suspense and surprise.** Ely, Frankel and Kamenica (2015) define two kinds of entertainment from this belief curve. **Surprise** is how much the belief jumps after each turn. **Suspense** is how much it is expected to jump before each turn. A match where $p_t$ stays near 0.5 and moves a lot is exciting. A match where one player leads from the start is not.

The profiler computes surprise as the average size of the jumps, and suspense as the root-mean-square size of the jumps. Root-mean-square counts big jumps more than small jumps.

$$\text{surprise} = \frac{1}{T}\sum_{t=1}^{T} |p_t - p_{t-1}|, \qquad \text{suspense} = \sqrt{\frac{1}{T}\sum_{t=1}^{T} (p_t - p_{t-1})^2}$$

- $T$ is the number of turns in the match.
- The profiler averages each value over all simulated matches.

> **Watch out:** In the original paper, suspense looks forward: it is the expected size of the next jump, before the shot. The profiler uses the jumps that really happened. This is a practical stand-in, not the exact definition. Also, $p_t$ is a rule of thumb. Nobody fitted it to real match results. [CODE]

[FIGURE: Schematic, not data. Two belief curves p_t over 10 turns, y-axis 0 to 1, a dashed line at 0.5. Curve A "dramatic": crosses 0.5 three times and ends at 1. Curve B "one-sided": rises steadily from 0.5 to 1. Label the turn-to-turn jumps on curve A with small vertical arrows, labeled "surprise = average arrow length".]

**Drama and fairness.** Browne and Maire (2010) proposed ways to score board games automatically. The model takes three ideas from them:

- **Lead changes**: how often the leader switches during a match.
- **Comebacks**: how often the winner was behind at some point by more than 5% of the leader's points.
- **First-player balance**: does Player 1 win too often? The model computes

$$\mathcal{B} = 1 - 2\,|W_{P1} - 0.5|$$

where $W_{P1}$ is the fraction of matches that Player 1 wins (a tie counts as half). If Player 1 wins half the time, $\mathcal{B} = 1$. If Player 1 always wins, $\mathcal{B} = 0$.

### 2.9 Compression and MDL: elegant levels are short to describe

**Intuition.** Compare two descriptions. "Put a peg at (100, 200), a peg at (110, 205), a peg at (120, 212) …" for 80 pegs. Or: "draw a sine wave from here to there and put 80 pegs on it". Both make the same level. The second one is much shorter. The **Minimum Description Length (MDL)** principle says that the shortest description captures the real structure.

**Peggle example.** The model counts a rough number of "free numbers" that you need to describe a level. A line or curve costs about 6 numbers. A loose peg costs 2 numbers, its x and y. [HAND-SET]

$$K_{\text{geom}} = 6 \cdot L_{\text{lines}} + 2 \cdot N_{\text{free}}$$

- $L_{\text{lines}}$ is the number of distinct lines in the level.
- $N_{\text{free}}$ is the number of pegs that are not part of a slide.
- $K_{\text{geom}}$ is the description length, counted in numbers.

> **Example:** `ribbon_waves` has 5 lines and 53 loose pegs. So $K_{\text{geom}} = 6 \times 5 + 2 \times 53 = 136$. `squiggly_circle` is one ring of 192 pegs, so $K_{\text{geom}} = 6$.

The model then asks: how much controlled behavior does the level give per unit of description? A level that does a lot with a simple shape is "elegant". Section 3.7 gives the formula.

The source is the information-theory notes of the project. The MDL idea itself is standard in information theory.

### 2.10 Three small statistics tools

The model uses three more tools. They are short.

**Gini coefficient: are the pegs used equally?** The Gini coefficient measures inequality. It comes from economics, where it measures how unequally a country shares its income. A value of 0 means every peg is hit equally often. A value near 1 means a few pegs get almost all hits and the rest are never touched.

$$G = \frac{\sum_{i}\sum_{j} |\pi_i - \pi_j|}{2N\sum_i \pi_i}$$

- $\pi_i$ is the fraction of the 1801 shots that hit peg $i$.
- $N$ is the number of pegs.
- The top sums all differences between pairs of pegs.

**Perplexity: how many good options are there, really?** Suppose a screen has 19 regions, and each region has a best shot. If all best shots are equally good, a player has 19 real options. If one region is far better than the rest, the player has about 1 real option. **Perplexity** turns this into one number: $2^{H}$, where $H$ is the entropy of the shares. It is the "effective number" of options.

**Jaccard distance: how different are two shots?** Take the sets of pegs that two shots hit. The Jaccard distance is

$$d_J = 1 - \frac{\text{number of pegs in both sets}}{\text{number of pegs in either set}}$$

0 means the same pegs. 1 means no pegs in common.

### 2.11 Search-based level generation and MAP-Elites

**Intuition.** The long-term plan is to let the computer design levels. A simple way is to generate many levels, score each one, and keep the best. Togelius, Yannakakis, Stanley and Browne (2011) call this **search-based procedural content generation**. The score function is the key part. The LQI is meant to be that score.

**The problem with one score.** If you only keep the single highest score, the search finds one kind of level and copies it forever. You get 1000 versions of `ribbon_waves`.

**MAP-Elites** fixes this. Mouret and Clune (2015) proposed it. You pick a few **behaviour descriptors**, for example "fraction of slide pegs" and "skill horizon". These form a grid, like a map. Each cell of the map holds the best level found so far with those features. The search fills the whole map. You get the best slide-heavy level, the best open-grid level, and so on. This family of methods is called **quality-diversity**. Gravina and co-authors (2019) apply it to level generation.

[FIGURE: A 2D grid, x-axis "slide fraction" from 0 to 1 in 5 columns, y-axis "skill horizon" in 4 rows. Some cells are filled with small level icons and a rating, some are empty. Caption: "MAP-Elites keeps the best level in each cell, not only the single best level."]

The model proposes a descriptor vector $\mathbf{b}(L)$ for this: slide fraction, skill horizon, red-hit safety and a style profile. [PROPOSED] No code uses MAP-Elites yet.

## 3. The model

### 3.1 The big picture

The model has three layers.

1. **Three data tiers** collect raw facts. They differ in cost.
2. **Five pillars** turn the facts into five ratings from 0 to 1.
3. **One formula** combines the five ratings into the LQI.

[FIGURE: Flowchart, top to bottom. Top box: "Level (pegs, shapes, lines)". Three arrows down to three boxes: "Tier 0: geometry only, < 1 ms", "Tier 1: 1801-aim sweep, about 0.5 to 5 s", "Tier 2: 1v1 bot matches, about 15 to 120 s" (time estimates from the original notes). Arrows from tiers to five pillar boxes: Tier 0 → Pillar V. Tier 1 → Pillars I, II, III (and also Pillar V). Tier 2 → Pillar IV. All five pillars → one box "LQI = ½ arithmetic mean + ½ geometric mean".]

### 3.2 The three data tiers

**Tier 0: geometry only.** The profiler reads the level file. It runs no physics. It counts pegs by color and shape. It counts slide pegs and lines. It measures how spread out the pegs are, and how mirror-symmetric the level is. This takes less than a millisecond.

**Tier 1: the full sweep.** The profiler fires one shot at every aim index, 1801 shots, from the starting board. For each shot it records:

- the order in which the ball scored pegs,
- the order of all bounces, on pegs, walls and the bucket,
- the points, the red pegs hit, the styles earned, and whether the bucket caught the ball,
- where the ball left the screen.

The original notes estimate 0.5 to 5 seconds per level for this tier. Pillars I, II and III come from this tier.

**Tier 2: 1v1 matches.** The profiler plays full matches between bots. It plays 8 matches of sector bot against sector bot, both with fine aim. Then it plays a **skill ladder**: 8 matches each for fine against sloppy, sector against random, and tactical against sector. In the ladder, the bots swap seats, so that each bot plays as Player 1 half of the time. Pillar IV comes from this tier. [CODE]

### 3.3 Pillar I: agency and control

**The question.** When the player aims, does the aim matter?

**Why it matters for fun.** Players enjoy a game when their choices change what happens. If the result is the same wherever you aim, or random wherever you aim, the aim is not a real choice.

**What it combines.** The first three inputs use the route label at noise $\sigma = 2$. [CODE]

| Input | What it means | Divide by [HAND-SET] | Weight [HAND-SET] |
|---|---|---|---|
| Mutual information $I_2(A; O_{\text{route}})$ | Bits of control over the route | 4.2 bits | 0.35 |
| Controllability $\mathcal{C}_2$ | Fraction of route variety under control | 0.80 | 0.25 |
| Empowerment $\mathfrak{E}_2$ | Control for a smart player | 5.2 bits | 0.20 |
| Active aim space $1 - f_{\text{dead}}$ | Fraction of aims that hit at least one peg | 1 | 0.20 |

"Divide by" means: the profiler divides the raw value by this target, then cuts the result to the range 0 to 1. A value at or above the target gets a full 1.

### 3.4 Pillar II: skill horizon and dynamics

**The question.** How far into a shot does the player's aim still matter?

**Why it matters for fun.** In a good shot, the player plans a path: "hit the left ribbon, roll down, bounce into the middle". If the aim stops mattering after two pegs, the rest of the shot is a lottery. The player watches, but does not own the result.

**The information curve.** For each hit number $k = 1, \dots, 15$, the profiler computes $I_2(A; Y_k)$. Here $Y_k$ is the $k$-th peg that the ball scored, or "none" if the shot scored fewer than $k$ pegs. [CODE]

From this curve, the model takes:

- **Integrated trajectory agency** ($\text{AUC}_{\text{MI}}$): the sum of the curve over $k = 1$ to 15. It is large only if shots are long **and** the aim still decides the later pegs. The unit is bits.
- **Skill horizon** ($k_{1/2}$): the hit number where the curve falls to half of its value at $k = 1$. It is like a half-life. If the curve never falls to half within 15 hits, the profiler reports 15.
- **Deep cascade survival** $\alpha(10)$: the fraction of shots that score at least 10 pegs.

The model also looks at **shot basins**. Walk along the aim indices from 0 to 1800. Compare each shot with its neighbour using the Jaccard distance on their first five pegs. If the distance is 0.40 or less, the two shots belong to the same basin. A basin of three or more aims is **aimable**: a player with $\pm 1$ step of noise stays inside it. A shorter basin is a **knife edge**.

| Input | Divide by [HAND-SET] | Weight [HAND-SET] |
|---|---|---|
| $\text{AUC}_{\text{MI}}$ (scored pegs) | 60 bits | 0.40 |
| Deep cascade survival $\alpha(10)$ | 0.85 | 0.25 |
| Skill horizon $k_{1/2}$ (scored pegs) | 15 hits | 0.20 |
| Aimable basin fraction | 0.50 | 0.15 |

> **Intuition:** Picture a flashlight beam. On a board of round pegs, the beam widens at every peg and soon lights everything. The aim is lost. On a board with slides, the beam is re-focused at each slide and stays narrow. The information curve measures the width of the beam, hit by hit.

### 3.5 Pillar III: the tactical landscape of one turn

**The question.** When the player looks at the board, how many good options are there, and how varied are they?

**Why it matters for fun.** A level with one obvious best shot is solved. A level with many good shots in different directions gives the player a real decision every turn.

| Input | What it means | Divide by [HAND-SET] | Weight [HAND-SET] |
|---|---|---|---|
| Effective competitive sectors | Perplexity of the best expected points per block of 100 aims. Section 2.10. | 18 | 0.30 |
| Distinct first-hit pegs $N_{\text{first}}$ | How many different pegs a shot can hit first | 40 | 0.25 |
| Style-shot rate $r_{\text{style}}$ | Fraction of aims that earn at least one style | 0.35 | 0.25 |
| Peg equity $(1 - G_{\text{peg}}) \times \min(1, N/80)$ | Are pegs used equally? Small levels get less credit. | 1 | 0.20 |

"Expected points" here means the average over the three neighbour aims of a $\pm 1$-step bot, where a shot that misses red counts as zero. [CODE]

A low $N_{\text{first}}$ points to **shielding**: an outer layer of pegs blocks the launcher's view of everything behind it.

### 3.6 Pillar IV: 1v1 drama, balance and skill

**The question.** When two players play a full match on this level, is the match good?

**Why it matters for fun.** A level can be beautiful for one shot and still give bad matches. Matches can be too short, too long, one-sided, or unfair to the second player.

| Input | What it means | Formula or target [HAND-SET] | Weight [HAND-SET] |
|---|---|---|---|
| Pacing | Mean match length in turns | Peak at 10.5 turns. Falls linearly to 0 at 1 and at 20 turns. 0 if under 2 turns. | 0.25 |
| Completion | Fraction of matches that end because all red pegs are gone | Used as is | 0.15 |
| First-player balance $\mathcal{B}$ | Section 2.8 | Used as is | 0.20 |
| Drama | Lead changes, comebacks and suspense | $0.4 \cdot \frac{\text{lead changes}}{1.5} + 0.3 \cdot \frac{\text{comeback rate}}{0.60} + 0.3 \cdot \frac{\text{suspense}}{0.18}$, cut to 1 | 0.20 |
| Skill gradient | Section 2.7 | $0.5 \cdot \frac{W_{\text{fine vs sloppy}} - 0.5}{0.40} + 0.5 \cdot \frac{W_{\text{sector vs random}} - 0.5}{0.50}$, cut to 1 | 0.20 |

A level with zero red pegs gets its Pillar IV rating multiplied by 0.05. Without red pegs, 1v1 does not work. [CODE]

The skill gradient maps a 50% win rate (no skill effect) to 0. It maps 90% for fine aim, and 100% against the random bot, to the full 1.

### 3.7 Pillar V: structural elegance

**The question.** Is the level built from a good mix of parts, spread well over the screen, and simple for what it does?

**Why it matters for fun.** This pillar is the least direct. It rewards designs that the billiard theory of Section 2.6 predicts to play well. It also rewards levels that are easy to read: a few clear shapes, not a cloud of random dots.

**Waveguide–scatterer balance.** Let $f_{\text{slide}}$ be the fraction of pegs that sit on a slide. Then

$$B_{\text{wg}} = 4 \, f_{\text{slide}} \, (1 - f_{\text{slide}})$$

- If there are no slides ($f_{\text{slide}} = 0$), $B_{\text{wg}} = 0$.
- If everything is slides ($f_{\text{slide}} = 1$), $B_{\text{wg}} = 0$.
- At an even mix ($f_{\text{slide}} = 0.5$), $B_{\text{wg}} = 1$.

[FIGURE: Line chart of B_wg = 4f(1−f) for f from 0 to 1, a hill with peak 1 at f = 0.5. Mark the five levels as dots on the curve: circle_level (0.00, 0.00), ribbon_waves (0.60, 0.96), mustache (0.73, 0.79), slide (0.99, 0.05), squiggly_circle (1.00, 0.00).]

**Spatial entropy.** Split the screen into an 8 × 8 grid. Count the share of pegs in each cell. The entropy of these shares, divided by its maximum of 6 bits, gives a number from 0 to 1. A high value means the pegs cover the screen well.

**MDL efficiency.**

$$\eta_{\text{MDL}} = \frac{\text{AUC}_{\text{MI}}}{\log_2(1 + K_{\text{geom}})}$$

- The top is the integrated trajectory agency from Pillar II, in bits.
- The bottom is the description length from Section 2.9, also turned into bits.
- The ratio is "bits of controlled behaviour per bit of design".

| Input | Divide by [HAND-SET] | Weight [HAND-SET] |
|---|---|---|
| Waveguide–scatterer balance $B_{\text{wg}}$ | 1 | 0.45 |
| Spatial entropy | 1 | 0.25 |
| MDL efficiency $\eta_{\text{MDL}}$ | 8.5 | 0.30 |

### 3.8 Putting the pillars together: the LQI

The model has five pillar ratings $Q_1, \dots, Q_5$, each from 0 to 1. It combines them with weights $w = (0.22, 0.23, 0.20, 0.23, 0.12)$. [HAND-SET] The weights add up to 1. Pillar V has the smallest weight, because it is the least direct link to fun.

$$\text{LQI} = \frac{1}{2}\underbrace{\sum_{p=1}^{5} w_p\, Q_p}_{\text{arithmetic mean}} + \frac{1}{2}\underbrace{\prod_{p=1}^{5} \max(0.01,\, Q_p)^{w_p}}_{\text{geometric mean}}$$

- $Q_p$ is the rating of pillar $p$.
- $w_p$ is its weight.
- $\sum$ means "add up". $\prod$ means "multiply together".
- $\max(0.01, Q_p)$ replaces a zero rating with 0.01, so that the product is never exactly zero.

**Why two kinds of mean?** The two means behave differently when one pillar is weak.

- The **arithmetic mean** adds. A strong pillar can make up for a weak one. If four pillars are 1.0 and one is 0.0, the arithmetic mean is still about 0.8.
- The **geometric mean** multiplies. One weak pillar pulls the whole result down. If one pillar is near 0, the product is near 0, whatever the other pillars do.

> **Intuition:** Think of a chair with five legs. The arithmetic mean asks "how long are the legs on average?". The geometric mean asks "can you sit on it?". One missing leg barely changes the average length, but you fall over.

The model takes half of each. A level with one broken pillar loses a lot, but not everything. A level with balanced pillars gets almost the same value from both means.

> **Example:** On `ribbon_waves`, the pillars are all high and close together. The arithmetic mean is 0.932 and the geometric mean is 0.932. On `slide`, Pillar IV is 0.017 because the level has no red pegs. The arithmetic mean is 0.402, but the geometric mean is only 0.219. The LQI lands between them, at 0.310. [MEASURED]

[FIGURE: Grouped bar chart. For each of the five levels, two bars: "arithmetic mean" and "geometric mean", with a dot for the LQI. Data from Table 4.2.]

## 4. Results on the five levels

All numbers in this section are [MEASURED]. They come from `results/analysis/level_evaluation_profiles.json`. The profiler ran all levels with `campaigns/ribbon/config.v1.json`, except `mustache`, which used `fixtures/mustache/config.dev.v1.json`. Section 5 explains why this matters.

### 4.1 The level at a glance (Tier 0)

| Level | Pegs | Red | Slide pegs | Lines | Slide fraction | $B_{\text{wg}}$ | Mirror symmetry | Spatial entropy | $K_{\text{geom}}$ |
|---|---|---|---|---|---|---|---|---|---|
| `ribbon_waves` | 133 | 25 | 80 | 5 | 0.602 | 0.959 | 0.419 | 0.849 | 136 |
| `mustache` | 99 | 16 | 72 | 9 | 0.727 | 0.793 | 1.000 | 0.670 | 108 |
| `circle_level` | 25 | 10 | 0 | 0 | 0.000 | 0.000 | 0.245 | 0.721 | 50 |
| `squiggly_circle` | 192 | 10 | 192 | 1 | 1.000 | 0.000 | 0.180 | 0.828 | 6 |
| `slide` | 73 | 0 | 72 | 3 | 0.986 | 0.054 | 0.142 | 0.476 | 20 |

### 4.2 The overall rating

| Level | LQI | Arithmetic mean | Geometric mean |
|---|---|---|---|
| `ribbon_waves` | 0.932 | 0.932 | 0.932 |
| `mustache` | 0.775 | 0.778 | 0.772 |
| `circle_level` | 0.515 | 0.555 | 0.475 |
| `squiggly_circle` | 0.500 | 0.533 | 0.466 |
| `slide` | 0.310 | 0.402 | 0.219 |

[FIGURE: Horizontal bar chart of LQI per level, sorted from high to low, x-axis 0 to 1. Values: ribbon_waves 0.932, mustache 0.775, circle_level 0.515, squiggly_circle 0.500, slide 0.310.]

### 4.3 The five pillars

| Level | I: Agency | II: Skill horizon | III: Tactics | IV: 1v1 | V: Elegance |
|---|---|---|---|---|---|
| `ribbon_waves` | 0.954 | 0.870 | 0.958 | 0.947 | 0.944 |
| `mustache` | 0.926 | 0.808 | 0.715 | 0.653 | 0.790 |
| `circle_level` | 0.954 | 0.222 | 0.437 | 0.759 | 0.266 |
| `squiggly_circle` | 0.929 | 0.195 | 0.525 | 0.582 | 0.375 |
| `slide` | 0.919 | 0.393 | 0.310 | 0.017 | 0.364 |

[FIGURE: Radar chart (or grouped bar chart) with five axes, one per pillar, 0 to 1. One line per level. Data from the table above.]

The table shows the main story at once:

- Pillar I is almost the same for all levels, from 0.92 to 0.95. It does not separate good levels from bad ones. Section 4.10 explains why.
- Pillar II separates the levels most clearly. The two slide-and-peg levels score 0.81 and 0.87. The others score 0.20 to 0.39.
- Pillar IV catches the two game-rule problems: `slide` has no red pegs, and `mustache` is unfair to Player 2.

### 4.4 Inside the pillars

Each pillar is a weighted mix of inputs. This table shows each input after the profiler divides it by its target and cuts it to 0 to 1.

| Pillar | Input (weight) | `ribbon_waves` | `mustache` | `circle_level` | `squiggly_circle` | `slide` |
|---|---|---|---|---|---|---|
| I | Mutual information (0.35) | 1.00 | 0.94 | 1.00 | 1.00 | 0.95 |
| I | Controllability (0.25) | 0.82 | 0.81 | 0.91 | 1.00 | 0.99 |
| I | Empowerment (0.20) | 0.99 | 0.98 | 1.00 | 1.00 | 0.98 |
| I | Active aim space (0.20) | 1.00 | 1.00 | 0.88 | 0.65 | 0.72 |
| II | $\text{AUC}_{\text{MI}}$ (0.40) | 1.00 | 0.85 | 0.23 | 0.22 | 0.46 |
| II | Deep cascade $\alpha(10)$ (0.25) | 1.00 | 0.99 | 0.02 | 0.01 | 0.30 |
| II | Skill horizon (0.20) | 1.00 | 1.00 | 0.30 | 0.17 | 0.29 |
| II | Aimable basins (0.15) | 0.13 | 0.14 | 0.44 | 0.47 | 0.52 |
| III | Competitive sectors (0.30) | 1.00 | 0.99 | 0.96 | 0.53 | 0.00 |
| III | First-hit breadth (0.25) | 1.00 | 0.38 | 0.33 | 1.00 | 0.83 |
| III | Style rate (0.25) | 1.00 | 0.67 | 0.09 | 0.08 | 0.06 |
| III | Peg equity (0.20) | 0.79 | 0.78 | 0.22 | 0.48 | 0.44 |
| IV | Pacing (0.25) | 0.93 | 0.57 | 0.43 | 0.01 | 0.00 |
| IV | Completion (0.15) | 0.88 | 1.00 | 0.38 | 0.25 | 1.00 |
| IV | First-player balance (0.20) | 1.00 | 0.25 | 1.00 | 1.00 | 1.00 |
| IV | Drama (0.20) | 0.94 | 0.87 | 1.00 | 0.90 | 0.00 |
| IV | Skill gradient (0.20) | 0.97 | 0.69 | 0.97 | 0.81 | 0.00 |
| V | Waveguide balance (0.45) | 0.96 | 0.79 | 0.00 | 0.00 | 0.05 |
| V | Spatial entropy (0.25) | 0.85 | 0.67 | 0.72 | 0.83 | 0.48 |
| V | MDL efficiency (0.30) | 1.00 | 0.89 | 0.29 | 0.56 | 0.74 |

> **Watch out:** For `slide`, Pillar IV completion and balance are 1.00, but the match ends on turn 1. The level has no red pegs, so "all red pegs cleared" is true at once. The 0.05 red-peg gate then pulls Pillar IV down to 0.017.

### 4.5 Key single-shot metrics (Tier 1)

| Metric | `ribbon_waves` | `mustache` | `circle_level` | `squiggly_circle` | `slide` |
|---|---|---|---|---|---|
| Mean pegs hit per shot | 20.5 | 27.4 | 3.4 | 1.8 | 5.1 |
| Dead aims (hit no peg) | 0.0% | 0.0% | 12.2% | 35.3% | 27.6% |
| Shots that hit red | 96.7% | 90.8% | 63.9% | 12.0% | 0.0% |
| Aims safe for red at ±1 step (≥ 80% red) | 90.5% | 78.1% | 46.7% | 5.7% | 0.0% |
| Shots with any style | 41.1% | 23.4% | 3.3% | 2.9% | 2.1% |
| Distinct first-hit pegs | 42 | 15 | 13 | 116 | 33 |
| Peg-hit Gini | 0.211 | 0.217 | 0.303 | 0.523 | 0.516 |
| Effective competitive sectors | 18.01 | 17.84 | 17.32 | 9.53 | 0.00 |
| Aimable basin fraction | 6.5% | 6.8% | 22.2% | 23.3% | 25.8% |
| Knife-edge fraction | 93.5% | 93.2% | 65.6% | 41.5% | 46.6% |

### 4.6 The skill-horizon curves

These two tables are the heart of Pillar II. The first one gives the mutual information between the intended aim and the $k$-th scored peg, at $\sigma = 2$. The second gives the fraction of shots that score at least $k$ pegs.

**Mutual information $I_2(A; Y_k)$, in bits:**

| $k$ | `ribbon_waves` | `mustache` | `circle_level` | `squiggly_circle` | `slide` |
|---|---|---|---|---|---|
| 1 | 4.66 | 3.18 | 2.97 | 4.95 | 4.32 |
| 2 | 4.56 | 4.08 | 3.50 | 3.19 | 3.65 |
| 3 | 3.99 | 3.37 | 2.20 | 2.00 | 2.82 |
| 4 | 4.01 | 3.32 | 1.67 | 1.33 | 2.28 |
| 5 | 4.06 | 3.31 | 1.25 | 0.90 | 1.97 |
| 6 | 4.19 | 3.25 | 0.88 | 0.45 | 1.75 |
| 7 | 4.21 | 3.26 | 0.57 | 0.19 | 1.60 |
| 8 | 4.22 | 3.30 | 0.36 | 0.11 | 1.48 |
| 9 | 4.19 | 3.35 | 0.23 | 0.06 | 1.39 |
| 10 | 4.15 | 3.36 | 0.10 | 0.04 | 1.31 |
| 11 | 4.06 | 3.41 | 0.03 | 0.04 | 1.22 |
| 12 | 3.98 | 3.46 | 0.02 | 0.03 | 1.12 |
| 13 | 3.89 | 3.48 | 0.00 | 0.03 | 0.98 |
| 14 | 3.78 | 3.43 | 0.00 | 0.03 | 0.83 |
| 15 | 3.62 | 3.38 | 0.00 | 0.03 | 0.71 |
| **Sum ($\text{AUC}_{\text{MI}}$)** | **61.57** | **50.95** | **13.79** | **13.39** | **27.44** |
| **Skill horizon $k_{1/2}$** | **15+** | **15+** | **4.44** | **2.60** | **4.39** |

[FIGURE: Line chart, x-axis hit number k from 1 to 15, y-axis mutual information in bits from 0 to 5. One line per level, data from the table above. Add a light shaded area under the ribbon_waves line labeled "AUC = 61.57 bits".]

**Fraction of shots with at least $k$ scored pegs, $\alpha(k)$:**

| $k$ | `ribbon_waves` | `mustache` | `circle_level` | `squiggly_circle` | `slide` |
|---|---|---|---|---|---|
| 1 | 1.00 | 1.00 | 0.88 | 0.65 | 0.72 |
| 3 | 1.00 | 0.99 | 0.60 | 0.28 | 0.45 |
| 5 | 0.98 | 0.91 | 0.30 | 0.12 | 0.34 |
| 10 | 0.88 | 0.84 | 0.01 | 0.00 | 0.25 |
| 15 | 0.72 | 0.81 | 0.00 | 0.00 | 0.13 |

[FIGURE: Line chart of α(k), the cascade survival, x-axis k from 1 to 15, y-axis 0 to 1, one line per level. Data from the table above.]

**How to read the curves.** On `ribbon_waves`, the curve starts at 4.66 bits and is still at 3.62 bits at the fifteenth peg. Also, 88% of shots reach ten pegs. The aim decides a long cascade. On `squiggly_circle`, the curve starts higher, at 4.95 bits, but falls below half by hit 2.6. Most shots end after one or two pegs. On `circle_level`, the curve falls to almost zero by hit 10. Only 1% of shots get that far.

> **Watch out:** On `mustache`, the curve rises from hit 1 (3.18 bits) to hit 2 (4.08 bits). This looks odd, because information about the aim cannot grow along a chain. The explanation: the second peg is not computed from the first peg alone. It depends on the full position and speed of the ball. Also, the label "no second peg" carries information of its own. So the curve does not have to fall at every step.

### 4.7 Control under more and more aim noise

This table shows the route mutual information $I_\sigma(A; O_{\text{route}})$ for five noise widths. The LQI uses only the $\sigma = 2$ column.

| Noise $\sigma$ (steps) | Angle | `ribbon_waves` | `mustache` | `circle_level` | `squiggly_circle` | `slide` |
|---|---|---|---|---|---|---|
| 1 | ±0.1° | 4.98 | 4.58 | 5.37 | 5.38 | 4.30 |
| 2 | ±0.2° | 4.28 | 3.93 | 4.81 | 5.06 | 3.98 |
| 5 | ±0.5° | 3.26 | 2.99 | 3.96 | 4.53 | 3.52 |
| 10 | ±1.0° | 2.51 | 2.31 | 3.32 | 4.05 | 3.18 |
| 20 | ±2.0° | 1.83 | 1.70 | 2.70 | 3.52 | 2.85 |

[FIGURE: Line chart, x-axis noise σ on a log scale (1, 2, 5, 10, 20), y-axis route mutual information in bits. One line per level. Data from the table above.]

This table holds a surprise. The two simple levels, `circle_level` and `squiggly_circle`, give **more** control over the route than `ribbon_waves`. And they lose control more slowly as the noise grows.

The reason is that their shots are short. A shot that hits one or two pegs and falls out is easy to predict. The player controls it well, but there is little to control. Section 4.10 comes back to this.

### 4.8 1v1 match results (Tier 2)

Each value comes from 8 matches. A win rate can only be 0%, 12.5%, 25%, and so on, in steps of 12.5%.

| Metric | `ribbon_waves` | `mustache` | `circle_level` | `squiggly_circle` | `slide` |
|---|---|---|---|---|---|
| Mean match length (turns) | 9.9 | 6.4 | 15.9 | 19.9 | 1.0 |
| Ended with all red cleared | 87.5% | 100% | 37.5% | 25.0% | (no red) |
| Ended with balls exhausted | 12.5% | 0% | 62.5% | 75.0% | 0% |
| Penalties per match | 2.0 | 1.5 | 11.1 | 11.5 | 0.0 |
| Player 1 win rate | 50% | 87.5% | 50% | 50% | 50% |
| First-player balance $\mathcal{B}$ | 1.00 | 0.25 | 1.00 | 1.00 | 1.00 |
| Lead changes per match | 1.25 | 0.88 | 1.50 | 1.25 | 0.00 |
| Comeback win rate | 62.5% | 50.0% | 100% | 62.5% | 0% |
| Mean deficit overcome | 0.51 | 0.38 | 0.82 | 0.47 | 0.00 |
| Suspense | 0.178 | 0.234 | 0.276 | 0.150 | 0.000 |
| Surprise | 0.119 | 0.169 | 0.189 | 0.070 | 0.000 |
| Fine aim beats sloppy aim | 87.5% | 75.0% | 87.5% | 75.0% | 50% |
| Sector bot beats random bot | 100% | 87.5% | 100% | 100% | 50% |
| Tactical bot beats sector bot (not in LQI) | 50% | 100% | 62.5% | 50% | 50% |

[FIGURE: Bar chart of mean match length per level, with a shaded band from 9 to 13 turns labeled "pacing sweet spot (peak 10.5)". Values: ribbon_waves 9.9, mustache 6.4, circle_level 15.9, squiggly_circle 19.9, slide 1.0.]

### 4.9 Level by level

**`ribbon_waves`: LQI 0.932, the best.** This level does almost everything well. Every aim hits at least one peg. The average shot scores 20 pegs, and 88% of shots reach ten. The aim still carries 3.6 bits of information at the fifteenth peg. Shots can start from 42 different first pegs, and 41% of aims earn a style bonus, mostly slides. In 1v1, matches last about 10 turns, both seats win equally often, and the better bot wins clearly. The mix of 60% slide pegs and 40% round pegs sits near the top of the balance curve in Section 3.7.

**`mustache`: LQI 0.775, second.** The slides work well here too. Shots are long (27 pegs on average) and the skill horizon reaches 15. Two problems lower the rating. First, only 15 different pegs can be the first hit. The top mustache shields the two below it from the launcher. Second, a shot clears so much of the board that matches last only 6.4 turns. Player 1 won 7 of the 8 matches. The earlier notes suggest that Player 1 profits from the first big clear. That is a hypothesis. With 8 matches, it is also possible that part of this result is chance.

**`circle_level`: LQI 0.515, third.** A small grid of 25 round pegs and no slides. The aim controls the first two pegs well. After that, the round pegs scatter the ball and the shot ends. The average shot hits only 3.4 pegs, and 1% of shots reach ten. Style shots are rare, at 3.3%. In 1v1, red pegs are hard to hit reliably, so players take about 11 penalties per match, and most matches end because the balls run out. The level is fair and dramatic (every winner came from behind), but each shot is shallow.

**`squiggly_circle`: LQI 0.500, fourth.** All 192 pegs form one closed ring. Most shots hit the outside of the ring and fall away. 35% of aims hit nothing. The average shot hits 1.8 pegs. Only 12% of shots hit red, and only 5.7% of aims are safe for red with ±1 step of aim noise. Matches drag to almost 20 turns, and 75% of them end with no balls left.

**`slide`: LQI 0.310, last.** This is a test level for style shots, not a real 1v1 level. It has no red pegs, so the 1v1 pillar collapses. It still gets a fair Pillar II rating (0.39), because a quarter of shots ride a slide for ten pegs or more.

### 4.10 Three lessons from the numbers

**Lesson 1: control is not enough.** Pillar I is nearly flat across the five levels. The simple levels even score higher on route control (Section 4.7). Their shots are short, so they are easy to predict. Control over nothing interesting is not fun. Pillar II fixes this: it asks for control over a long, rich cascade. That is why the model weights Pillar II heavily and why $\text{AUC}_{\text{MI}}$ is its main input.

**Lesson 2: slides carry intent.** The two levels with a real mix of slides and round pegs have the longest skill horizons and the highest LQI. This agrees with the billiard picture of Section 2.6. The pure round-peg level and the pure slide ring both do badly, for opposite reasons.

**Lesson 3: a good shot level is not always a good 1v1 level.** `mustache` has excellent single shots, but its matches are short and one-sided. Only the match simulations of Tier 2 show this.

> **Watch out:** The basin metric points the other way. On `ribbon_waves`, 93.5% of aims are knife edges: the first five pegs change between neighbour aims. By this metric, `squiggly_circle` looks more aimable. The reason is that long cascades change their first five pegs often, even when the route stays the same. The aimable-basin input has a small weight (0.15) and does not change the ranking. But it shows that "aimable" depends on how you define "the same shot".

## 5. Limits and open questions

The model is a useful first tool. It is not a proof that a level is fun. This section lists what it does not see and which numbers are guesses.

### 5.1 Numbers that a person chose

- **Pillar weights.** The five weights (0.22, 0.23, 0.20, 0.23, 0.12) and the weights inside each pillar are choices. No data fixed them. [HAND-SET]
- **Targets.** Each input is divided by a target, for example 60 bits or 0.85. Many of these targets sit at or just under the `ribbon_waves` value: 4.2 bits of mutual information (`ribbon_waves`: 4.28), 5.2 bits of empowerment (5.15), 60 bits of $\text{AUC}_{\text{MI}}$ (61.57), 0.85 deep cascade (0.88), 40 first-hit pegs (42), suspense 0.18 (0.178), MDL efficiency 8.5 (8.67). So the LQI partly measures "how close is this level to `ribbon_waves`". That is a fair start, because the team likes that level. But it explains why `ribbon_waves` gets 1.00 on many inputs. It also means that the LQI cannot yet show a level that is better than `ribbon_waves`.
- **The 50/50 mix of means.** Other mixes are possible. Nobody tested which one matches human opinion best.
- **Other constants.** The pacing peak of 10.5 turns, the 0.40 Jaccard threshold, the 5% comeback threshold, the 0.05 red-peg gate, the 6-and-2 rule for $K_{\text{geom}}$, and the logistic scale $S_{\text{scale}}$ are all choices.

### 5.2 Small samples

Tier 2 plays 8 matches per test. A win rate of 87.5% means 7 wins out of 8. With 8 matches, a fair coin gives 7 or more heads about 3.5% of the time. So the `mustache` first-player problem is likely real, but not certain. Lead changes, comebacks and suspense from 8 matches also have wide error ranges. More matches per level would make Pillar IV more trustworthy. The simulator is fast enough for this.

### 5.3 Bots are not people

All match results come from simple bots. The sector bot picks the best gross points in each block of aims and ignores the red-peg penalty. Human players think ahead, take risks on purpose, and get bored. The model has no data from real players. Nobody has yet checked that a higher LQI means that people enjoy a level more.

### 5.4 Only the first shot is studied in detail

Tier 1 fires all 1801 shots from the starting board only. Later in a match, the board has fewer pegs and can behave very differently. Pillars I, II and III do not see this. Pillar IV sees it only through the bots.

### 5.5 Theory that is not measured

The model uses chaos theory as its main explanation for Pillar II. But the profiler computes no Lyapunov exponent. The estimate "one round peg makes an aim error 14 times bigger" comes from a textbook formula, not from the simulator. The information curve is the real measurement. The theory explains why the curves look the way they do.

### 5.6 Different physics for one level

`mustache` ran with its own configuration file. That file has stronger gravity (1000 against 700), a faster launch (800 against 600), and different wall and ball-ball bounce values. So the comparison between `mustache` and the other four levels is not exact.

### 5.7 What the model does not capture

- **Looks.** Color, theme and visual beauty play no part.
- **Readability for a human.** The model measures how predictable a shot is for a perfect calculator with noisy hands. A human must also *see* the likely path. Mirror symmetry and spatial entropy are only rough stand-ins.
- **Learning curve and difficulty over time.** The model does not ask whether a player gets better with practice on this level.
- **Moving pegs.** The single-shot sweep runs in a static-geometry mode. This report does not examine how the model handles levels whose pegs move.
- **Solo mode.** Pillar IV is only about 1v1.

### 5.8 Open questions

1. Do human players rank the five levels in the same order as the LQI? A small play test can answer this.
2. Which targets and weights best match human rankings? With enough rated levels, you can fit them to data instead of choosing them.
3. Does Pillar I need a new design, given that it barely separates the levels? One option is to replace it with control over the hit set, or with control at a larger noise width.
4. How does the LQI change if the sweep starts from mid-match boards, not only the starting board?
5. Which behaviour descriptors make the best MAP-Elites map for level generation?
6. With more matches, does the `mustache` first-player advantage stay near 87.5%?

### 5.9 Where the notes and the code disagree

The report follows the code. These are the differences found:

1. **Number of aim sectors.** The notes say 18 sectors of 100 aims. The code makes 19: eighteen of 100 aims, plus one sector that holds only aim index 1800. That is why `ribbon_waves` shows 18.01 "effective sectors", which is more than 18.
2. **Inputs to the LQI.** The notes describe four outcome labels, surprise, deficit overcome, and the tactical bot. The LQI uses only the route label at $\sigma = 2$. It does not use surprise, deficit overcome or the tactical-bot result. Pillar I also includes the dead-aim fraction, and Pillar II includes the aimable-basin fraction. The model note does not list these two.
3. **Peg equity.** The code multiplies $1 - G_{\text{peg}}$ by $\min(1, N/80)$. The notes do not mention this factor.
4. **Pacing.** The code also sets pacing to 0 when a match lasts under 2 turns.
5. **Empowerment.** The notes call it "exact". The code runs 25 rounds of Blahut–Arimoto and is an estimate.
6. **Suspense.** The notes cite the paper's forward-looking definition. The code uses realized jumps. The code comment calls the belief model "calibrated", but no fit happens.
7. **Route label.** The literature notes describe a route label with the first peg and an 8 × 8 grid. The code uses a 4 × 4 grid, a pegs-hit tier, the exit quarter, a style flag and a red flag. The main model note agrees with the code.
8. **MDL efficiency.** The literature notes put route mutual information on top of the fraction. The model note and the code use $\text{AUC}_{\text{MI}}$.
9. **Aim step.** One literature note says one step is 0.09°. The configuration gives a 90° limit on each side and 1800 steps, so one step is 0.1°.
10. **Pillar headers in the code.** The comment at the top of the profiler lists a finite-time Lyapunov exponent and a Pareto frontier. The code computes neither.

## 6. Glossary

**Active aim space.** The fraction of aim indices whose shot hits at least one peg. The other aims are dead aims.

**Aim index.** A whole number from 0 to 1800 that selects the launch angle. Neighbouring indices differ by 0.1°.

**Aim noise.** A random shift between the aim that the player intends and the aim that the game fires. The model draws it evenly from $\pm\sigma$ steps.

**Aimable basin.** A run of three or more neighbouring aims whose first five scored pegs are almost the same. A player with ±1 step of noise stays inside it.

**Annular peg.** A peg shaped like a short piece of a curved band. Annular pegs often form curved slides.

**Arithmetic mean.** The usual average: add the values, then divide. With weights, multiply each value by its weight before you add.

**Bit.** A unit of information. One bit is the answer to one fair yes-or-no question.

**Blahut–Arimoto algorithm.** A step-by-step method that finds the channel capacity. It moves weight toward inputs whose outputs stand out.

**Bot.** A computer player. The model uses sector, sloppy, random and tactical bots.

**Bucket.** The moving catcher at the bottom of the screen. A catch gives bonus points.

**Cascade survival, $\alpha(k)$.** The fraction of shots that score at least $k$ pegs.

**Channel.** In information theory, anything that takes an input and gives a possibly noisy output. Here, the input is the intended aim and the output is the shot outcome.

**Channel capacity.** The highest mutual information that a channel can reach, when you pick the best way to use its inputs.

**Chaos.** Behaviour where tiny differences at the start grow into large differences later.

**Comeback win rate.** The fraction of decided matches where the winner was once behind by more than 5% of the leader's points.

**Conditional entropy, $H(O \mid A)$.** The uncertainty about the outcome that remains after you know the intended aim. Also called equivocation.

**Controllability, $\mathcal{C}$.** Mutual information divided by outcome entropy. It is the fraction of outcome variety that the player controls.

**Empowerment, $\mathfrak{E}$.** The channel capacity from the player's aim to the outcome. It is the control that a smart player who picks the best angles can reach.

**Entropy, $H$.** A measure of variety or surprise in an outcome, in bits.

**Fever.** The game state after all red pegs are cleared. The multiplier is ×100 and special buckets appear.

**First-player balance, $\mathcal{B}$.** A rating from 0 to 1 of how fair the level is to the player who goes second. 1 means each player wins half the time.

**Galton board.** A board of pins where a falling ball bounces left or right at each pin. A grid of round pegs behaves like one.

**Geometric mean.** An average where you multiply the values and take a root. One value near zero pulls it toward zero.

**Gini coefficient, $G$.** A measure of inequality from 0 to 1. Here, 0 means every peg is hit equally often.

**Information bottleneck.** The idea that a good summary keeps the information that matters for a goal and drops the rest.

**Integrated trajectory agency, $\text{AUC}_{\text{MI}}$.** The sum of the mutual information between aim and the $k$-th scored peg, for $k = 1$ to 15. It is high only for long shots that the aim still controls.

**Jaccard distance.** One minus the share of pegs that two shots have in common. 0 means the same pegs, 1 means none in common.

**Knife edge.** An aim whose basin is shorter than three aims. A tiny aim error changes the shot.

**Level Quality Index (LQI).** The final rating of a level, from 0 to 1. It is half the weighted arithmetic mean and half the weighted geometric mean of the five pillar ratings.

**Logistic function.** An S-shaped curve that turns any number into a value between 0 and 1. The model uses it to turn a score gap into a win chance.

**Lyapunov exponent, $\lambda$.** The average rate at which small differences grow per bounce. Positive means chaos, negative means paths come together.

**MAP-Elites.** A search method that keeps the best solution in each cell of a map of features, not only the single best one.

**Minimum Description Length (MDL).** The principle that the shortest description of something captures its real structure.

**MDL efficiency, $\eta_{\text{MDL}}$.** Integrated trajectory agency divided by the description length of the level in bits.

**Multiplier.** The factor that grows as players clear red pegs. It reaches ×100 at fever.

**Mutual information, $I(A;O)$.** How much knowing the intended aim tells you about the outcome, in bits. It is entropy minus conditional entropy.

**Outcome label.** A short description of what a shot did. The model uses hit set, score tier, tactical label and route label.

**Perplexity.** Two raised to the power of an entropy. It is the effective number of equally good options.

**Pillar.** One of the five parts of the model. Each pillar gives a rating from 0 to 1.

**Quality-diversity.** A family of search methods that look for many different good solutions, not one best solution.

**Red-peg penalty.** In 1v1, a shot with no red peg earns nothing and costs the player 25% of the banked points.

**Route label.** The main outcome label. It records the screen region of the hit pegs, the number of pegs on a log scale, the exit quarter, a style flag and a red flag.

**Sector.** A block of 100 neighbouring aim indices. The sector bot picks the best shot in each sector.

**Shielding.** A layer of pegs that blocks the launcher's direct view of the pegs behind it.

**Skill gradient.** A rating of how clearly the better bot wins. It uses fine-against-sloppy aim and sector-against-random matches.

**Skill horizon, $k_{1/2}$.** The hit number at which the aim's information about the scored peg falls to half of its value at the first hit.

**Slide.** A line of pegs with no gap, along which the ball can roll. The model also calls it a waveguide.

**Style shot.** A bonus for a special kind of shot, for example a slide, a long shot or an off-the-wall bounce.

**Surprise.** The average size of the jump in win chance from one turn to the next.

**Suspense.** In the paper, the expected size of the next jump in win chance. In the profiler, the root-mean-square size of the jumps that happened.

**Waveguide–scatterer balance, $B_{\text{wg}}$.** $4 f_{\text{slide}}(1 - f_{\text{slide}})$, where $f_{\text{slide}}$ is the fraction of pegs on a slide. It is 1 for an even mix of slides and loose pegs, and 0 for all of one kind.

## 7. References

Papers with a local copy are in `papers/`. The file name follows each entry.

**Information theory and empowerment**

- C. E. Shannon (1948). *A Mathematical Theory of Communication*. Bell System Technical Journal 27. `shannon_1948_mathematical_theory_of_communication.pdf`
- C. Salge, C. Glackin and D. Polani (2014). *Empowerment — An Introduction*. In *Guided Self-Organization: Inception*, Springer. arXiv:1310.1863. `salge_glackin_polani_2014_empowerment_introduction.pdf`
- N. Tishby, F. C. Pereira and W. Bialek (2000). *The Information Bottleneck Method*. arXiv:physics/0004057. `tishby_pereira_bialek_2000_information_bottleneck.pdf`
- *The Geometry of Empowerment* (2026). arXiv:2610.07796. `geometry_of_empowerment_2026.pdf`
- *Information-Theoretic Policy Pre-Training with Empowerment* (2025). arXiv:2510.05996. `empowerment_policy_pretraining_2025.pdf`

**Skill, luck and game design**

- J. Jerdee and M. E. J. Newman (2023). *Luck, skill, and depth of competition in games and social hierarchies*. arXiv:2312.04711. `luck_skill_depth_of_competition_2023.pdf`
- *Quantifying Skill and Chance: A Unified Framework for the Geometry of Games* (2025). arXiv:2511.11611. `quantifying_skill_and_chance_geometry_of_games_2025.pdf`
- J. Ely, A. Frankel and E. Kamenica (2015). *Suspense and Surprise*. Journal of Political Economy 123(1). No local copy.
- C. Browne and F. Maire (2010). *Evolutionary Game Design*. IEEE Transactions on Computational Intelligence and AI in Games 2(1). No local copy.

**Chaos and billiards**

- *Estimating Lyapunov Exponents in Billiards* (2019). arXiv:1904.05108. `estimating_lyapunov_exponents_in_billiards_2019.pdf`
- *Dynamics of the No-Slip Galton Board* (2022). arXiv:2208.07790. `dynamics_of_no_slip_galton_board_2022.pdf`
- H. van Beijeren, J. R. Dorfman, H. A. Posch and Ch. Dellago (2004). *The Kolmogorov-Sinai Entropy and Lyapunov Spectrum of the Many-Dimensional Dilute Random Lorentz Gas*. arXiv:nlin/0404034. `lyapunov_spectrum_random_lorentz_gas_2004.pdf`

**Level generation and quality-diversity**

- J. Togelius, G. N. Yannakakis, K. O. Stanley and C. Browne (2011). *Search-Based Procedural Content Generation: A Taxonomy and Survey*. IEEE TCIAIG 3(3). `togelius_2011_search_based_pcg.pdf`
- J.-B. Mouret and J. Clune (2015). *Illuminating search spaces by mapping elites*. arXiv:1504.04909. `mouret_clune_2015_map_elites.pdf`
- D. Gravina, A. Khalifa, A. Liapis, J. Togelius and G. N. Yannakakis (2019). *Procedural Content Generation through Quality Diversity*. IEEE CoG. arXiv:1907.04053. `gravina_2019_pcg_through_quality_diversity.pdf`

**Project sources**

- `wiki/brainstorming/mathematical_evaluation_model.md`: the original model note.
- `wiki/brainstorming/literature_review.md`: the original literature notes.
- `wiki/brainstorming/information_theory.md` and `wiki/brainstorming/level_design.md`: the first idea notes.
- `scripts/profile_level.jl`: the profiler. The report follows this code where the notes differ.
- `results/analysis/level_evaluation_profiles.json`: the measured profiles.
