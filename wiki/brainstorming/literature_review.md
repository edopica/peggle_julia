# Literature Synthesis: Information Theory, Chaotic Billiards, Game Theory & PCG for Peggle Evolved

This document synthesizes the theoretical literature archived in [`papers/`](file:///home/kurapica/Projects/pevo/julia_clone/papers/README.md) and bridges four distinct mathematical disciplines into a unified foundation for evaluating **Peggle Evolved** levels:

1. **Shannon Information Theory & Agent Empowerment** (Player Agency vs. Uncontrollable Chaos)
2. **Ergodic Theory of Chaotic Billiards & Galton Boards** (Why Convex Pegs Disperse and Concave Slides Focus)
3. **Competitive Game Theory & Entertainment Utility** (Risk–Reward Trade-offs, Suspense, Surprise, Drama, and Skill Depth in 1v1)
4. **Search-Based PCG, Minimum Description Length, & Quality-Diversity** (Expressive Range and Behavioral Efficiency)

---

## 1. Information Theory & Empowerment: Resolving the "Determinism Paradox"

In [information_theory.md](file:///home/kurapica/Projects/pevo/julia_clone/wiki/brainstorming/information_theory.md), the core intuition is to measure **Outcome Entropy** $H(O)$ (behavioral diversity) and **Mutual Information** $I(A; O)$ (player agency/controllability) between the player's action $A$ and the shot outcome $O$.

### 1.1 The Determinism Paradox and the Motor-Execution Channel
Because `PeggleSim` is a **bit-exact deterministic physics engine** ([reference.md](file:///home/kurapica/Projects/pevo/julia_clone/wiki/context/reference.md)), a naive evaluation over a fixed board state $s$ faces a fundamental mathematical trap: if the player can select a discrete aim index $a \in \mathcal{A} = \{0, 1, \dots, 1800\}$ with zero execution error, then the outcome $O = \Phi_s(a)$ is a deterministic function of $a$. Consequently:
$$H(O \mid A) = 0 \implies I(A; O) = H(O) - H(O \mid A) = H(O) \quad \text{and} \quad \frac{I(A; O)}{H(O)} \equiv 1$$
even on a completely chaotic pinball board where shifting the aim by $0.09^\circ$ ($\pm 1$ step) produces an unrelated trajectory!

The resolution comes directly from **Shannon's noisy-channel coding theorem** ([Shannon 1948](file:///home/kurapica/Projects/pevo/julia_clone/papers/shannon_1948_mathematical_theory_of_communication.pdf)) and **Sensorimotor Empowerment Theory** ([Salge, Glackin, & Polani 2014](file:///home/kurapica/Projects/pevo/julia_clone/papers/salge_glackin_polani_2014_empowerment_introduction.pdf); [The Geometry of Empowerment 2026](file:///home/kurapica/Projects/pevo/julia_clone/papers/geometry_of_empowerment_2026.pdf)):
- A human player (or a bot in [campaign.jl](file:///home/kurapica/Projects/pevo/julia_clone/julia/PeggleSim/src/campaign.jl#L40-L43)) does not command the executed angle $\tilde{A}$ directly; instead, the player selects an **intended aim** $A \in \mathcal{A}$, which passes through a **bounded-precision execution kernel** $K_\sigma(\tilde{a} \mid a)$ (for instance, $\tilde{A} \sim \text{Unif}[a-\sigma, a+\sigma]$ where $\sigma \in \{1, 2, 5, 10, 20\}$ aim steps represents motor/perceptual precision):
  $$A \xrightarrow{K_\sigma(\tilde{a}\mid a)} \tilde{A} \xrightarrow{\Phi_s} X_1 \longrightarrow X_2 \longrightarrow \dots \longrightarrow X_k \longrightarrow O$$
- Under this composite Markov channel $W_\sigma(o \mid a) = \sum_{\tilde{a} \in \mathcal{A}} K_\sigma(\tilde{a} \mid a) \mathbb{I}(\Phi_s(\tilde{a}) = o)$:
  1. **Outcome Diversity** $H(O) = -\sum_{o} P(o) \log_2 P(o)$ measures the total repertoire of behaviors the board can produce.
  2. **Noise-Induced Equivocation (Local Chaos)** $H_\sigma(O \mid A) = \mathbb{E}_A\big[H(O \mid A=a)\big]$ measures how much outcome uncertainty remains *after* the player has aimed with precision $\sigma$. If adjacent angles $\tilde{a} \in [a-\sigma, a+\sigma]$ diverge wildly, $H_\sigma(O \mid A) \approx H(O)$.
  3. **Effective Player Agency (Mutual Information)** $I_\sigma(A; O) = H(O) - H_\sigma(O \mid A)$ measures the number of bits of reliable control the player exerts over outcome $O$ at motor precision $\sigma$.
  4. **Normalized Controllability** $\mathcal{C}_\sigma(O) = \frac{I_\sigma(A; O)}{H(O)} \in [0, 1]$ measures the fraction of outcome variability governed by skill rather than knife-edge sensitivity.

### 1.2 Empowerment ($\mathfrak{E}_\sigma$) vs. Uniform Mutual Information ($I_\sigma$)
As shown by [Salge, Glackin, & Polani (2014)](file:///home/kurapica/Projects/pevo/julia_clone/papers/salge_glackin_polani_2014_empowerment_introduction.pdf) and [Empowerment Policy Pre-Training (2025)](file:///home/kurapica/Projects/pevo/julia_clone/papers/empowerment_policy_pretraining_2025.pdf), an intelligent player does not sample aim angles uniformly ($p(a) = 1/1801$). When parts of a level are chaotic or empty, a skilled player focuses their shots into **controllable basins**. **Empowerment** is defined as the Shannon channel capacity:
$$\mathfrak{E}_\sigma(s) = \max_{p(a)} I_\sigma(A; O \mid s)$$
computed exactly via the **Blahut–Arimoto iterative algorithm**:
$$q^{(t)}(o) = \sum_a p^{(t)}(a) W_\sigma(o \mid a), \qquad p^{(t+1)}(a) = \frac{p^{(t)}(a) \exp_2\!\big(D_{\text{KL}}(W_\sigma(\cdot \mid a) \,\|\, q^{(t)}(\cdot))\big)}{\sum_{a'} p^{(t)}(a') \exp_2\!\big(D_{\text{KL}}(W_\sigma(\cdot \mid a') \,\|\, q^{(t)}(\cdot))\big)}$$
Comparing $\mathfrak{E}_\sigma(O)$ with $I_\sigma(A; O)$ yields a crucial diagnostic:
- High $I_\sigma(A; O)$ and high $\mathfrak{E}_\sigma(O)$: the **entire board** offers clean, controllable shot corridors.
- Low $I_\sigma(A; O)$ but moderate $\mathfrak{E}_\sigma(O)$: the board is mostly dead space or chaos, with only a few isolated controllable "pockets."

### 1.3 The Information Bottleneck and Outcome Representation
By [Tishby, Pereira, & Bialek (2000)](file:///home/kurapica/Projects/pevo/julia_clone/papers/tishby_pereira_bialek_2000_information_bottleneck.pdf), evaluating $I_\sigma(A; O)$ on a single raw representation can be misleading:
- Exact hit-set hashes $O_{\text{hitset}} = \text{hash}(\{p_{i_1}, \dots, p_{i_m}\})$ treat two shots that hit 14 of the same 15 pegs on a slide as completely orthogonal symbols ($H(O_{\text{hitset}}) \approx 9\text{--}10$ bits), inflating noise equivocation.
- Conversely, scalar final score $O_{\text{score}}$ collapses spatially distinct routes that happen to yield similar points into the same bin.
- Therefore, our model evaluates a **compressed Macro-Route Bottleneck Representation** $O_{\text{route}} = (\text{first\_peg}, \text{centroid\_grid\_cell}_{8\times 8}, \lfloor\log_2(1+M)\rfloor, \text{exit\_zone}, \text{style\_mask})$ alongside $O_{\text{hitset}}$, $O_{\text{score}}$, and the 1v1 tactical tuple $O_{\text{tactical}} = (\mathbb{I}_{\text{red}}, \mathbb{I}_{\text{bucket}}, \text{style\_mask}, \text{peg\_tier})$.

---

## 2. Chaotic Billiards & Galton Boards: Physics of the Skill Horizon

Why do some Peggle levels preserve the player's intent for 10+ peg hits while others become unpredictable lottery machines after 2 bounces? The answer lies in the **ergodic theory of hyperbolic billiards and Galton boards** ([Estimating Lyapunov Exponents in Billiards 2019](file:///home/kurapica/Projects/pevo/julia_clone/papers/estimating_lyapunov_exponents_in_billiards_2019.pdf); [Lyapunov Spectrum of the Random Lorentz Gas 2004](file:///home/kurapica/Projects/pevo/julia_clone/papers/lyapunov_spectrum_random_lorentz_gas_2004.pdf); [Dynamics of the No-Slip Galton Board 2022](file:///home/kurapica/Projects/pevo/julia_clone/papers/dynamics_of_no_slip_galton_board_2022.pdf)).

### 2.1 Convex Circle Pegs Are Exponentially Dispersing (Sinai Scatterers)
Consider a ball of radius $r_b = 6\text{ px}$ colliding elastically/inelasticity with a fixed **circular peg** of radius $r_p = 10\text{ px}$ (effective interaction circle of radius $R = r_b + r_p = 16\text{ px}$) after travelling a free-flight distance $\ell$ between collisions at incidence angle $\phi \in (-\pi/2, \pi/2)$ relative to the surface normal.

By standard billiard wavefront geometry (Sinai 1970; Chernov & Markarian 2006; [arXiv:1904.05108](file:///home/kurapica/Projects/pevo/julia_clone/papers/estimating_lyapunov_exponents_in_billiards_2019.pdf)), an incoming beam with angular spread $\delta \theta_0$ and curvature $\kappa_0$ acquires after collision an outgoing wavefront curvature:
$$\kappa_k^+ = \kappa_k^- + \frac{2}{R \cos \phi_k}, \qquad \frac{\delta \theta_k}{\delta \theta_{k-1}} \approx 1 + \frac{2 \ell_k}{R \cos \phi_k} > 1$$
Letting $\bar{\ell}$ denote the mean free path between circular pegs (typically $\bar{\ell} \approx 60\text{--}120\text{ px}$ in Peggle, while $R = 16\text{ px}$ and $\langle \cos \phi \rangle = \pi/4 \approx 0.785$), each circular-peg bounce multiplies angular uncertainty by:
$$\mathcal{M}_{\text{circle}} = 1 + \frac{2 \bar{\ell}}{R \langle \cos \phi \rangle} \approx 1 + \frac{160}{12.5} \approx 13.8 \quad (\approx 3.8\text{ bits of angular amplification per bounce!})$$
After just $k = 3$ consecutive bounces off isolated circular pegs, an initial aiming precision of $\delta \theta_0 = 1\text{ step} = 0.1^\circ = 1.75 \times 10^{-3}\text{ rad}$ expands to:
$$\delta \theta_3 \sim \delta \theta_0 \cdot (\mathcal{M}_{\text{circle}})^3 \approx 1.75 \times 10^{-3} \times 2600 \approx 4.5\text{ rad} > \pi$$
Completely erasing any memory of the fine aim adjustment!

### 2.2 Zero-Gap Slides & Concave Arcs Are Phase-Space Waveguides (Focusing / Funneling)
Now consider a **zero-gap line or curved annular ribbon** (`gap = 0`, such as the 5 ribbons in `ribbon_waves` or the handlebar curls in `mustache`). Along a smooth slide of curvature $\kappa_{\text{slide}}$:
- In inelastic grazing/rolling contact (`restitution = 0.8`), the normal velocity component $v_\perp$ damps toward zero ($v_\perp^{(n)} = 0.8^n v_\perp^{(0)} \to 0$) while the ball is guided along the 1D tangent manifold of the curve!
- Phase-space volume **contracts** onto the 1D slide attractor ($\lambda_\perp < 0$), and adjacent aim angles that enter the capture basin of the ribbon are **funneled** along the exact same sequence of 8–16 adjacent pegs, exiting the tip of the ribbon with a tightly constrained velocity vector!
- In dynamical-systems terms, **slides act as negative-Lyapunov phase-space relays (waveguides)** that reset wavefront divergence and extend the **Skill Horizon** $k_{1/2}$ deep into the shot.

> [!IMPORTANT]
> **The Fundamental Law of Peggle Geometry:**
> - **100% Circular Pegs** ($f_{\text{slide}} = 0$, e.g. a pure Galton grid) produces rapid exponential divergence ($\lambda > 0$), collapsing the bounce skill horizon $k_{1/2}$ to $\approx 1\text{--}2$ collisions and turning late-turn shots into pure roulette.
> - **100% Closed/Unbroken Slides** ($f_{\text{slide}} = 1$, e.g. `squiggly_circle`) creates rigid barriers or monotonous rails with low route diversity.
> - **Mixed Waveguide–Scatterer Architecture** ($f_{\text{slide}} \in [0.40, 0.70]$, as in `ribbon_waves` where $f_{\text{slide}} = 80/133 \approx 0.60$) achieves the optimal synthesis: circular pegs create branching decision points and chaotic excitement, while curved slides capture, focus, and transport trajectories across the board!

---

## 3. Competitive Game Theory & Entertainment Utility (1v1 Mode)

In Peggle Evolved's primary **1v1 shared-board mode** ([bot-campaign.md](file:///home/kurapica/Projects/pevo/julia_clone/wiki/context/bot-campaign.md); [game-mechanics.md](file:///home/kurapica/Projects/pevo/peggle_evolved/wiki/game-mechanics.md)), two players alternate shots on the same depleting board with three coupled strategic mechanics:
1. **Quadratic Turn Scoring & Escalating Red Multiplier**: $S_{\text{peg}} = \left(\sum_{j=1}^M v(p_j) \cdot \mu_j\right) \times M$, where $\mu \in \{1, 2, 3, 5, 10, 100\}$ escalates as the global percentage of cleared red pegs crosses $40\%, 60\%, 75\%, 88\%, 100\%$.
2. **Escalating Shared Bucket Bonus**: Catching the ball in the bucket awards $N_{\text{catches}} \times 2500$ points (`shared_bucket_hits` persists across both players).
3. **The $-25\%$ No-Red Penalty Gate**: If a shot finishes without hitting at least one red peg, the entire turn score is voided (`credited = 0`) AND the active player loses $\lfloor 0.25 \cdot B \rfloor$ of their banked score $B$!

### 3.1 Turn-Level Risk–Reward Decision Theory
Under execution uncertainty $\tilde{a} \sim K_\epsilon(\cdot \mid a)$, each aim choice $a \in \mathcal{A}$ is a lottery characterized by:
- **Red-Hit Survival Probability**: $p_{\text{red}}(a) = \mathbb{P}(\text{hit red} \mid a, \epsilon) \in [0, 1]$.
- **Conditional Expected Score**: $\mu_{S\mid \text{red}}(a) = \mathbb{E}[S(\tilde{a}) \mid \text{red}(\tilde{a}), a]$.
- **Expected Net Banked Change (1v1 Utility)**:
  $$U_{\text{1v1}}(a \mid B, \epsilon) = p_{\text{red}}(a) \mu_{S\mid \text{red}}(a) - \big(1 - p_{\text{red}}(a)\big) \lfloor 0.25 B \rfloor$$
Notice that $U_{\text{1v1}}(a \mid B, \epsilon)$ depends explicitly on the player's current banked score $B$!
- When $B = 0$ (Turn 1), the penalty $\lfloor 0.25 B \rfloor = 0$, so maximizing expected utility reduces to maximizing $p_{\text{red}}(a) \mu_{S\mid \text{red}}(a)$ (aggressive high-upside play).
- When $B$ is large (late game with a lead), $0.25 B$ is massive, shifting optimal play toward high-reliability $p_{\text{red}}(a) \to 1$ shots!
- Conversely, a trailing player late in the match must seek high-variance style/slide/bucket/fever shots to overcome the deficit.
A well-designed 1v1 level supports this strategic richness by providing both **wide, safe red-clearing basins** ($p_{\text{red}} \approx 1$) and **narrower, high-reward slide/style/bucket corridors** across multiple sectors.

### 3.2 Suspense, Surprise, and Drama in Multi-Turn Campaigns
To evaluate whether full 1v1 matches on a level are exciting rather than lopsided snowballs, we combine two landmark game-theoretic frameworks:
1. **Suspense and Surprise** (Ely, Frankel, & Kamenica 2015, *Journal of Political Economy*; [Quantifying Skill and Chance 2025](file:///home/kurapica/Projects/pevo/julia_clone/papers/quantifying_skill_and_chance_geometry_of_games_2025.pdf)):
   Let $p_t = \mathbb{P}(\text{Player 1 wins} \mid s_t) \in [0, 1]$ denote the win-probability belief process after turn $t \in \{0, 1, \dots, T\}$, with $p_0 = 0.5$ and $p_T \in \{0, 1\}$.
   - **Suspense** measures ex-ante uncertainty about how much the *next* shot will shift the match outcome:
     $$\mathcal{U}_{\text{suspense}} = \mathbb{E}\left[ \sqrt{\frac{1}{T} \sum_{t=1}^T (p_t - p_{t-1})^2} \right]$$
   - **Surprise** measures the average realized magnitude of belief revisions per turn:
     $$\mathcal{U}_{\text{surprise}} = \mathbb{E}\left[ \frac{1}{T} \sum_{t=1}^T |p_t - p_{t-1}| \right]$$
2. **Evolutionary Game Design Aesthetics** (Browne & Maire 2010; [Jerdee & Newman 2023](file:///home/kurapica/Projects/pevo/julia_clone/papers/luck_skill_depth_of_competition_2023.pdf)):
   - **Drama ($\mathcal{D}_{\text{drama}}$)**: Quantifies comeback potential—the fraction of matches where the eventual winner trailed in banked score during the match, and the average maximum relative score deficit $\max_t \frac{B_{\text{loser},t} - B_{\text{winner},t}}{\max(B_{\text{loser},t}, B_0)}$ overcome by the winner.
   - **Lead-Change Frequency**: Mean number of times the score lead flips between Player 1 and Player 2 per match.
   - **First-Player Balance ($\mathcal{B}_{\text{1v1}}$)**: Closeness of Player 1's win rate to $50\%$ under symmetric policies: $\mathcal{B}_{\text{1v1}} = 1 - 2|W_{\text{P1}} - 0.5|$.
   - **Skill Differentiation ($\mathcal{S}_{\text{skill}}$)**: Win-rate separation across a hierarchy of policies:
     - *Tactical Skill Gradient*: $W(\pi_{\text{tactical}} \text{ vs. } \pi_{\text{sector}})$ — does a bot that models execution jitter $\epsilon$ and the $-25\%$ red-miss penalty beat a naive gross-score bot?
     - *Motor Skill Gradient*: $W(\pi_{\text{sector}}(\epsilon=1) \text{ vs. } \pi_{\text{sector}}(\epsilon=10))$ — does a player with fine aiming precision ($\pm 1$ step) reliably beat a sloppy aimer ($\pm 10$ steps)?
     - *Baseline Rationality Gradient*: $W(\pi_{\text{sector}} \text{ vs. } \pi_{\text{random}})$.

---

## 4. PCG, Minimum Description Length & Quality-Diversity

From [Togelius et al. (2011)](file:///home/kurapica/Projects/pevo/julia_clone/papers/togelius_2011_search_based_pcg.pdf), [Mouret & Clune (2015)](file:///home/kurapica/Projects/pevo/julia_clone/papers/mouret_clune_2015_map_elites.pdf), and [Gravina et al. (2019)](file:///home/kurapica/Projects/pevo/julia_clone/papers/gravina_2019_pcg_through_quality_diversity.pdf):
1. **Structural Minimum Description Length (MDL) & Behavioral Efficiency**:
   As noted in [information_theory.md](file:///home/kurapica/Projects/pevo/julia_clone/wiki/brainstorming/information_theory.md#L8), a level built from $L_{\text{lines}}$ parametric splines/arcs and $N_{\text{free}}$ standalone pegs has an effective generative description length $K_{\text{geom}}(L) \propto 6 L_{\text{lines}} + 2 N_{\text{free}}$.
   The **Behavioral Efficiency Ratio** $\eta_{\text{MDL}}(L) = \frac{I_\sigma(A; O_{\text{route}})}{\log_2(1 + K_{\text{geom}}(L))}$ rewards levels where simple, readable geometric forms generate rich, controllable trajectory dynamics.
2. **Quality-Diversity (MAP-Elites) Readiness**:
   When we transition from level analysis to level generation in future sessions, a single scalar fitness score is necessary but not sufficient—optimizing a single scalar alone converges to a single level archetype. Following [MAP-Elites](file:///home/kurapica/Projects/pevo/julia_clone/papers/mouret_clune_2015_map_elites.pdf), our evaluation model provides:
   - A scalar **Level Quality Index $\text{LQI}(L) \in [0, 1]$** (the Quality objective $f(L)$), AND
   - Orthogonal **Behavioral/Design Feature Coordinates** $\mathbf{b}(L) = (\text{Waveguide Fraction } f_{\text{slide}}, \text{Skill Horizon } k_{1/2}, \text{Red Safety } f_{\text{red}}, \text{Style Profile})$ so a future generator can illuminate the entire archive of high-quality Peggle levels!
