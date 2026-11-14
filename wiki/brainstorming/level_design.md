The conversation converged on a **Julia-side level design toolkit** built around interpretable descriptors rather than jumping straight to opaque ML embeddings.

The main tools are:

- **Level recipes / mathematical primitives**: represent a level as compositions such as `Swirl`, `Arc`, `Slide`, `Singles`, `Ring`, etc., optionally transformed with warps like bend, noise, pinch, or nonlinear deformations. This preserves the semantic origin of geometry and gives the procedural generator meaningful parameters to manipulate.

- **Explicit design descriptors**: compute a human-readable vector describing the level, e.g. `swirl`, `slides`, `singles`, `symmetry`, `density`, `complexity`, `movement`, and similar properties. These can be used directly as conditioning targets for generation: “generate something with high swirl, medium slide, low symmetry.”

- **Presence + salience metrics**: distinguish how much of a level uses a feature from how important that feature is to the level’s identity. For example, a swirl could contain only 20% of the pegs but still have very high visual/gameplay salience.

- **Headless simulation descriptors**: use the Julia simulator to automatically characterize how a level plays—mean bounce count, peg-hit distribution, cascade frequency, trajectory entropy, predictability, shot sensitivity, dead zones, bucket-entry rates, etc. This lets generation target gameplay properties in addition to geometry.

- **Search/optimization over generator parameters**: treat the desired descriptor vector as a target, generate recipes, measure their descriptors, compute an error, and iteratively adjust parameters. This turns Julia into a level-design search engine rather than just a random generator.

- **Preview + human feedback tooling**: show generated levels in a Julia-side browser/editor, let the designer approve/reject them or tag qualities, and store those judgments. Over time this data can train a preference model that ranks newly generated levels according to the designer’s taste.

- **Learned latent embeddings**: add these later, once many generated and evaluated levels exist. They can support similarity search, clustering, interpolation between level families, novelty detection, and learned generation. They should complement—not replace—the explicit descriptors used for human control.

Overall, the proposed workflow is:

```text
mathematical recipe
→ geometry
→ explicit design descriptors
→ headless simulation
→ behavioral descriptors
→ search / ranking / human feedback
→ optional learned embedding
```

This keeps the Lua game runtime small while making Julia the main environment for procedural generation, analysis, optimization, previewing, and eventually ML-assisted level design.
