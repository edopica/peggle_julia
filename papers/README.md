# Research Library — Level Evaluation, Information Theory, Game Theory & Chaotic Billiards

This directory contains locally archived open-access research papers supporting the mathematical evaluation and procedural generation model for **Peggle Evolved** (`julia_clone`).

For the full mathematical synthesis and evaluation model built from this literature, see:
- [Mathematical Level Evaluation Model](../wiki/brainstorming/mathematical_evaluation_model.md)
- [Literature Synthesis for Peggle Level Analysis](../wiki/brainstorming/literature_review.md)

---

## 1. Information Theory, Empowerment & Player Agency

| Local PDF File | Citation & Core Contribution | Role in Peggle Evolved Model |
| :--- | :--- | :--- |
| [shannon_1948_mathematical_theory_of_communication.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/shannon_1948_mathematical_theory_of_communication.pdf) | **C. E. Shannon (1948)**, *"A Mathematical Theory of Communication"*, Bell System Technical Journal, Vol. 27, pp. 379–423 & 623–656. | Defines Shannon entropy $H(O)$, conditional noise entropy $H(O\mid A)$, mutual information $I(A;O)$, channel capacity $C = \max_{p(a)} I(A;O)$, and the Data Processing Inequality along collision chains $A \to \tilde{A} \to X_1 \to \dots \to X_k$. |
| [salge_glackin_polani_2014_empowerment_introduction.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/salge_glackin_polani_2014_empowerment_introduction.pdf) | **C. Salge, C. Glackin, & D. Polani (2014)**, *"Empowerment — An Introduction"*, in *Guided Self-Organization: Inception*, Springer (`arXiv:1310.1863`). | Formalizes **Empowerment** $\mathfrak{E}(s) = \max_{p(a)} I(A; S' \mid s)$ as an agent-centric measure of control and perceived agency in dynamical environments. Computed in our profiler via the Blahut–Arimoto algorithm over the noisy aiming channel $K_\sigma(\tilde{a}\mid a)$. |
| [tishby_pereira_bialek_2000_information_bottleneck.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/tishby_pereira_bialek_2000_information_bottleneck.pdf) | **N. Tishby, F. C. Pereira, & W. Bialek (2000)**, *"The Information Bottleneck Method"*, 37th Allerton Conference (`arXiv:physics/0004057`). | Provides the rate–distortion / variational framework $\min [I(X; \tilde{X}) - \beta I(\tilde{X}; Y)]$ for compressing raw 1,801-angle trajectories into compact macro-route signatures $O_{\text{route}}$ and level embeddings that preserve tactical outcome information. |
| [geometry_of_empowerment_2026.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/geometry_of_empowerment_2026.pdf) | *"The Geometry of Empowerment"* (`arXiv:2610.07796`). | Connects information-theoretic empowerment to the Riemannian / phase-space geometry of state transitions and controllable manifolds. |
| [empowerment_policy_pretraining_2025.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/empowerment_policy_pretraining_2025.pdf) | *"Information-Theoretic Policy Pre-Training with Empowerment"* (`arXiv:2510.05996`). | Demonstrates how maximizing action-state mutual information identifies diverse, controllable behavioral skills in continuous/high-dimensional physics environments. |

---

## 2. Game Theory, Skill vs. Chance, Drama & Entertainment Utility

| Local PDF File | Citation & Core Contribution | Role in Peggle Evolved Model |
| :--- | :--- | :--- |
| [quantifying_skill_and_chance_geometry_of_games_2025.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/quantifying_skill_and_chance_geometry_of_games_2025.pdf) | *"Quantifying Skill and Chance: A Unified Framework for the Geometry of Games"* (`arXiv:2511.11611`). | Formalizes decision trees under stochastic execution, decomposing outcome variance into **Skill Gradient** (sensitivity to policy optimality) and **Turn Volatility / Suspense** ($\Sigma$). |
| [luck_skill_depth_of_competition_2023.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/luck_skill_depth_of_competition_2023.pdf) | **J. Jerdee & M. E. J. Newman (2023)**, *"Luck, skill, and depth of competition in games and social hierarchies"* (`arXiv:2312.04711`). | Probabilistic model of competitive depth and upset probabilities across skill ladders; motivates our cross-skill 1v1 tournament matrix ($\pi_{\text{tactical}}$ vs. $\pi_{\text{sector}}$ vs. $\pi_{\text{sloppy}}$ vs. $\pi_{\text{random}}$). |
| [evaluating_games_payoff_funness_2025.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/evaluating_games_payoff_funness_2025.pdf) | *"Evaluating Language Models' Evaluations of Games"* (`arXiv:2510.10930`). | Benchmarks game quality metrics (balance, decisiveness, strategic depth, payoff structure, funness) across two-player competitive games. |

### Key Non-Open-Archive Foundational Citations (Synthesized in `wiki/brainstorming/literature_review.md`)
- **C. Browne & F. Maire (2010)**, *"Evolutionary Game Design"*, IEEE Transactions on Computational Intelligence and AI in Games, 2(1), 1–16. (Defines mathematical aesthetics of 1v1 games: **Completion**, **Balance**, **Drama / Comeback Deficit Overcome**, **Lead-Change Frequency**, **Uncertainty**, and **Depth**).
- **J. Ely, A. Frankel, & E. Kamenica (2015)**, *"Suspense and Surprise"*, Journal of Political Economy, 123(1), 215–260. (Defines **Suspense** as the conditional variance of next-period win probability $\sqrt{\text{Var}_t(p_{t+1})}$ and **Surprise** as realized belief movement $|p_{t+1} - p_t|$ along the belief martingale $p_t = \mathbb{P}(\text{P1 wins} \mid \mathcal{F}_t)$).

---

## 3. Dynamical Systems, Chaotic Billiards & Galton Board Physics

| Local PDF File | Citation & Core Contribution | Role in Peggle Evolved Model |
| :--- | :--- | :--- |
| [dynamics_of_no_slip_galton_board_2022.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/dynamics_of_no_slip_galton_board_2022.pdf) | *"Dynamics of the No-Slip Galton Board"* (`arXiv:2208.07790`). | Models a gravity-driven ball bouncing through arrays of circular pegs (a Galton board / periodic Lorentz gas), characterizing phase-space attractors, periodic trapping, and chaotic dispersion. |
| [estimating_lyapunov_exponents_in_billiards_2019.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/estimating_lyapunov_exponents_in_billiards_2019.pdf) | *"Estimating Lyapunov Exponents in Billiards"* (`arXiv:1904.05108`). | Derives the collision-to-collision tangent map and Lyapunov exponent $\lambda = \frac{1}{\tau}\ln(1 + \frac{2\ell}{R\cos\phi})$ for convex dispersing scatterers vs. focusing curved boundaries. Explains why circular pegs destroy aim information exponentially while concave/linear slides preserve it. |
| [lyapunov_spectrum_random_lorentz_gas_2004.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/lyapunov_spectrum_random_lorentz_gas_2004.pdf) | **H. van Beijeren, J. R. Dorfman, H. A. Posch, & Ch. Dellago (2004)**, *"The Kolmogorov-Sinai Entropy and Lyapunov Spectrum of the Many-Dimensional Dilute Random Lorentz Gas"* (`arXiv:nlin/0404034`). | Relates scatterer density, mean free path $\bar{\ell}$, and scatterer radius $R$ directly to Kolmogorov–Sinai entropy production rate $h_{\text{KS}}$ (rate of information loss per unit time/collision). |

---

## 4. Procedural Content Generation (PCG), Expressive Range & Quality-Diversity

| Local PDF File | Citation & Core Contribution | Role in Peggle Evolved Model |
| :--- | :--- | :--- |
| [togelius_2011_search_based_pcg.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/togelius_2011_search_based_pcg.pdf) | **J. Togelius, G. N. Yannakakis, K. O. Stanley, & C. Browne (2011)**, *"Search-Based Procedural Content Generation: A Taxonomy and Survey"*, IEEE TCIAIG, 3(3), 172–186. | Establishes the taxonomy of Direct, Simulation-Based (Static vs. Dynamic Agent), and Interactive fitness functions for level evaluation and evolutionary search. |
| [mouret_clune_2015_map_elites.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/mouret_clune_2015_map_elites.pdf) | **J.-B. Mouret & J. Clune (2015)**, *"Illuminating search spaces by mapping elites"* (`arXiv:1504.04909`). | Introduces **MAP-Elites** (Quality-Diversity optimization): separating the **Quality Objective** (our Level Quality Index $\text{LQI}(L)$) from **Behavioral Descriptors** (e.g., Waveguide Fraction, Skill Horizon, Tactical Risk-Reward Asymmetry). |
| [gravina_2019_pcg_through_quality_diversity.pdf](file:///home/kurapica/Projects/pevo/julia_clone/papers/gravina_2019_pcg_through_quality_diversity.pdf) | **D. Gravina, A. Khalifa, A. Liapis, J. Togelius, & G. N. Yannakakis (2019)**, *"Procedural Content Generation through Quality Diversity"*, IEEE CoG (`arXiv:1907.04053`). | Unifies Expressive Range Analysis (Smith & Whitehead 2010) and Quality-Diversity algorithms for procedural level generation. |
