# Verifiche differite: simulazione continua di livelli (workflow bot 1v1)

Nota di rinvio. Le verifiche qui elencate **non** sono state eseguite e **non** bloccano
M4 (chiuso il 2026-10-21). Vanno riprese quando esisterà il workflow delle simulazioni
continue (bot 1v1): profilare livelli sarà un'attività a ore, non una misura singola, e
questi controlli servono a garantire throughput stabile e assenza di deriva nel tempo.

## Punto di partenza misurato (2026-10-21, host `omarchy`, commit `b57764f`)

Griglia completa (1.801 shot), `shot_bench --sweep --stride 1`, loop di simulazione
(tempi end-to-end esclusi dalla valutazione, come da decisione):

| livello | t=1 | t=12 | cand/s t12 | ~griglie/ora t12 |
| --- | ---: | ---: | ---: | ---: |
| `annular_dense` (`interchange/levels/squiggly_circle.v1.json`) | 4.52 s | 1.21 s | ~1.490 | ~2.950 |
| `mustache` (`fixtures/mustache/artifact/mustache.v1.json`) | 21.15 s | 4.13 s | ~436 | ~870 |

- Scaling su 12 thread (6 core + SMT): 3.7× (`annular_dense`), 5.1× (`mustache`).
- Steady state: **0 B/step, max 0** sui cinque probe (`results/m4/allocation-profile.json`),
  quindi nessuna pausa GC dentro lo step e RSS piatto (~570–646 MB) nelle misure brevi.
- I due commit (`6544414` vs `b57764f`) producono JSONL di sweep **byte-identici** e stessi
  step (media 900.0 / 168.3): il lavoro sull'allocazione non ha cambiato la velocità,
  come atteso (27 B/step contro step da ~3 µs).
- Dettaglio e dati grezzi: `tmp/shots-profiler-ab.md` e `tmp/shots-profiler/` (scratch,
  gitignored: vanno rigenerati se servono).

## Check da eseguire

### 1. Soak test di 30–60 minuti in un solo processo

Ciclare i livelli nello stesso processo e campionare una volta al minuto:

- `candidates/s` e `steps/s` del loop (deve restare piatto, non solo veloce);
- `Base.gc_live_bytes()` e RSS di processo (`Sys.maxrss()` oppure `scripts/bench_process.py`);
- crescita delle strutture riusate: `run_pool`, `seq_pool`, `peg_pool`, `spawn_pool`,
  `clear_lit`, `slide_cache`, `slide_award_pool`, e churn di creazione/distruzione mappe.

Criterio di passaggio: nessuna tendenza monotona di RSS oltre una soglia dichiarata prima
della misura, e throughput dell'ultimo quarto entro pochi punti percentuali dal primo.
Atteso piatto grazie a 0 B/step, ma **non ancora dimostrato**: le misure attuali sono
3 ripetizioni da 4 s, che non rivelano derive lente.

### 2. Driver multi-livello nello stesso processo

Forma corretta del profiling continuo: carica livello → sweep → reset → livello successivo,
riusando engine e pool (il warmup/JIT si paga una volta sola).

Oltre alla velocità, verificare che non ci sia **state bleed** tra livelli:
lo sweep dello stesso livello deve produrre lo stesso JSONL (stesso sha256) sia in un
processo fresco sia dopo altri livelli nello stesso processo, e due sweep consecutivi dello
stesso livello devono essere identici. Questo copre i reset (`reset_shot!`,
`reset_shot_engine!`) e la completezza dello svuotamento dei pool.

### 3. Scaling oltre i 12 thread

I numeri sopra sono di un laptop a 6 core. Misurare la stessa griglia completa a 24/48/64
thread su `deathstar` (o sulla macchina che ospiterà le simulazioni): il confronto con la
tabella `m4-bench` non è diretto, perché lì i passaggi sono da 91 candidati e il ramp-up
dei worker domina; la griglia completa è la misura onesta.

### 4. Costo per partita, non per griglia

Il workflow 1v1 consuma `1.801 × turni` candidati per partita. Tradurre i cand/s in
partite/ora e in costo per 1.000 partite, e dimensionare su quello le macchine da noleggio
(vedi `temp/cloud-cpu-rental-options.md`), non sui tempi di una singola griglia.

## Come si misura

```sh
export JULIA_DEPOT_PATH="$PWD/tmp/julia-depot:$HOME/.julia"
julia -t 12 --startup-file=no --project=julia/PeggleSim julia/PeggleSim/bin/shot_bench.jl \
  --sweep --level <LEVEL> --config <CONFIG> --balls 1 --stride 1 --threads 12 \
  --out tmp/.../sweep.jsonl --summary tmp/.../sweep.json
```

`summary.wall_seconds` è il tempo del **loop**; il tempo di processo (startup + JIT,
~13.5–14.5 s per processo su questo host) va misurato a parte con `scripts/bench_process.py`
(`/usr/bin/time` non è disponibile). Se il workflow riavvia Julia per ogni livello, quel
costo torna a contare: da qui il punto 2.
