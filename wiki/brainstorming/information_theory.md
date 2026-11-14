Information theory provides a useful framework for turning Peggle Evolved’s level-design questions into measurable quantities.

- **Entropy** can measure how diverse a level’s possible outcomes are. High outcome entropy means many different things can happen, but this alone does not imply good design: pure chaos can also have high entropy.
- **Mutual information** is especially promising as a measure of **player agency / skill expression**. For player input \(A\) and outcome \(O\), \(I(A;O)\) measures how much the chosen shot determines what eventually happens. This could distinguish large, rich levels from large levels where the initial aim is effectively forgotten and results become mostly luck-driven.
- A useful derivative could be a **normalized controllability metric**, such as \(I(A;O)/H(O)\), measuring what fraction of outcome variability remains attributable to player input.
- Mutual information can also be measured **throughout the trajectory**, e.g. \(I(A;X_k)\) after each collision. Its decay could define an **information half-life** or **skill horizon**: how long the simulation preserves meaningful information about the player’s original decision.
- MI should probably be computed against several outcomes rather than only final score: score, hit-set, route, orange pegs hit, landing region, event sequence, etc. A level may be noisy in score while still offering strong control over its route.
- **Minimum Description Length / compression** could characterize structural complexity. Since Julia may generate levels from composable mathematical primitives, the generative program itself provides a compact description of the geometry. This opens the door to comparing *behavioral richness per unit of structural complexity*.
- **Rate–distortion / information bottleneck ideas** could help build compact level embeddings: find a small latent representation that preserves the information needed to predict simulation behavior while discarding irrelevant geometric details.

Together, these suggest a useful Julia-side pipeline:

**generative primitives → geometry/design embedding → massive simulations → information-theoretic behavioral profile → generator filtering/optimization**

This would let the procedural generator target not just properties such as *swirl*, *slides*, density, or size, but behavioral goals like **high outcome diversity while maintaining high player controllability and a sufficiently long skill horizon**.
