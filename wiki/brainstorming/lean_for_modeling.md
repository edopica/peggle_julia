Here is how Lean maps onto your three areas of interest, along with concrete theorems we could formalize.
  ──────
  ### 1. Mathematical Modeling & Evaluation Theorems (mathematical_evaluation_model.md)

  Right now, the 5-pillar model in profile_level.jl:951-1019 is validated empirically on the corpus
  (ribbon_waves at 0.932 vs. mustache at 0.775, circle_level at 0.515, squiggly_circle at 0.500, slide at
  0.310). Lean 4 (with Mathlib) can turn the design claims in literature_review.md into certified design
  theorems:

  1. The LQI Bottleneck & AM–GM Ceiling Theorem
  In compute_composite_scores, LQI(L) is defined as the 50/50 hybrid of the weighted arithmetic and
  geometric means over Q₁, …, Q₅ ∈ [0, 1] with weights w = (0.22, 0.23, 0.20, 0.23, 0.12). We can prove in
  Lean:
      • Range & Monotonicity: Qₚ ∈ [0, 1] ⟹ LQI(L) ∈ [0.005, 1], strictly increasing in each Qₚ.
      • Single-Pillar Veto Inequality: If any single pillar Qₖ ≤ δ (e.g., slide having 0 red pegs ⟹ Q₄ ≤ 0.
      05, or a pure Galton grid having f_{slide} = 0 ⟹ B_{wg} = 0), then even if all other four pillars
      score 1.0, LQI(L) obeys the hard ceiling:


              1                     1                wₖ
    LQI(L) ≤ ─── (1 - wₖ(1 - δ)) + ─── (max(0.01, δ))
              2                     2

     This formally proves that a level **cannot** reach the "gold standard" tier (LQI ≥ 0.85) without
  simultaneously satisfying positive waveguide balance (f_{slide} ∈ (0, 1)), non-zero red pegs, and a non-
  trivial skill horizon.

  2. Resolution of the Determinism Paradox & Motor-Channel Capacity Bounds
  From literature_review.md` §1.1, because PeggleSim is deterministic (O = Φₛ(ã)), noise-free mutual
  information satisfies I₀(A; O) = H(O) even on pure pinball chaos. In Lean, modeling the discrete motor
  kernel K_σ(ã | a) over 𝒜 = {0, …, 1800} allows us to prove:
      • Zero-Noise Degeneracy: For σ = 0 and uniform prior, 𝒞₀(O) = I₀(A; O)/H(O) = 1 for every non-constant
      level L.
      • Basin-Width Controllability Bound: If a level's outcome map O(ã) has B contiguous constant-outcome
      basins of widths w₁, …, w_B, the noise equivocation H_σ(O | A) is bounded below by the fraction of aim
      angles within σ steps of a basin boundary. Thus high controllability 𝒞_σ(O) ≥ 1 - η provably requires
      mean basin width w̄ = Ω(σ/η).
  3. The 1v1 Risk–Reward Pareto Theorem (Pillar III & IV)
  In mathematical_evaluation_model.md` §2.3, a shot's expected utility at banked score B is:

    U   (a | B, ε) = μ   (a) - ⎛1 - p   (a)⎞⌊0.25B⌋
     1v1              net      ⎝     red   ⎠

  This is affine in P(B) = ⌊0.25B⌋. We can prove in Lean a Tactical Regime-Switching Theorem: for any two
  candidate shots a_{agg} (higher μ_{net}, lower p_{red}) and a_{safe} (lower μ_{net}, higher p_{red}),
  there is a unique threshold score B^* where the optimal decision flips from aggressive to conservative—and
  a level has state-dependent tactical depth (where optimal Turn-1 play differs from late-game leading play)
  if and only if the upper convex hull (Pareto frontier) of {(p_{red}(a), μ_{net}(a)) : a ∈ 𝒜} contains at
  least two distinct vertices.
  ──────
  ### 2. Stochastic Processes & Inverse Generation (stochastic_processes_and_inverse_generation.md)

  This is arguably the highest-value target for Lean in the entire repository, because "Trajectory-First /
  Inverse Billiard Synthesis" relies on geometric and dynamical claims that will directly become your level-
  generator's constraints:

  1. The Causal Swept-Tube Non-Interference Theorem (Pitfall 1)
  In stochastic_processes_and_inverse_generation.md` §3.1, you solve the "time-travel / causal occlusion"
  trap by defining the forbidden swept tube:

    ℱₖ = ⎧𝐲 ∈ ℝ² :  min   ‖𝐲 - γ(t)‖₂ ≤ r     + r   ⎫
         ⎩         0≤t<tₖ                ball    peg⎭

  In Lean, we can formalize the continuous/discrete CCD first-contact operator and prove:

  • Single-Bounce Inverse Bijection: Given incoming state (𝐱ₖ₋₁, 𝐯ₖ₋₁⁺), flight time Δtₖ > 0, and incidence
  angle φₖ ∈ (-π/2, π/2), the peg center 𝐜ₖ = 𝐱ₖ - (r_b + rₚ)𝐧̂(φₖ) is the unique circular peg location that
  produces the post-bounce velocity 𝐯ₖ⁺.
  • Monotonicity / Infill Invariance: If a board L₀ realizes trajectory γ on [0, T], then for any set of
  additional pegs P_{new} placed strictly outside ℱ_T, simulating on L₀ ∪ P_{new} produces the exact same
  trajectory γ on [0, T]. This proves that Stage 2 (Poisson-disk scatterer infill) in your 4-stage generator
  cannot corrupt the Stage 1 hero highways!

  2. The Billiard Wavefront Dispersion vs. Waveguide Funneling Theorem (Pitfall 2)
  In literature_review.md` §2.1–2.2 and stochastic_processes_and_inverse_generation.md` §3.2, we use the
  Sinai billiard wavefront curvature recurrence:

                   2           δθₖ                      2ℓₖ
    κₖ⁺ = κₖ⁻ + ────────,     ───── = 1 + ℓₖκₖ⁺ ≥ 1 + ────────
                R cos φₖ      δθₖ₋₁                   R cos φₖ

  In Lean, we can prove the Knife-Edge Bound: n consecutive convex scatterer bounces with flight distance ℓₖ
  ≥ ℓ_{min} expand angular uncertainty by at least (1 + 2ℓ_{min}/R)ⁿ, whereas interleaving a contracting
  waveguide map (with contraction factor ρ < 1) keeps the pre-image aim window bounded above the discrete
  grid spacing Δθ_{grid} for arbitrarily long cascades.
