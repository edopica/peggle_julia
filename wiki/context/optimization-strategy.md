# Ottimizzazione del simulatore: memoria, parallelismo e costo

Sintesi della discussione del 24 ottobre 2026, estesa il 25 ottobre con
un'analisi del codice, del notebook e degli stack archiviati della campagna.

Le sezioni 1–11 conservano il quadro delle strategie. Le sezioni 12–18
distinguono le evidenze disponibili dalle ipotesi, propongono le priorità e
valutano l'integrazione Julia/C/Odin. La raccomandazione è mantenere Julia
come ambiente principale e investigare **C per il primo kernel nativo**,
confrontandolo con una versione Julia equivalente.

L'analisi originale del 25 ottobre non esegue nuovi benchmark e non dimostra
un guadagno di un linguaggio sull'altro. Il seguito implementato e misurato
il 27 ottobre per la query statica è registrato in §13.2. Le nuove aggregazioni di misure già esistenti sono
registrate in [optimization-review-2026-10-25.json](../../results/analysis/optimization-review-2026-10-25.json).
Non è una ricerca sulle offerte commerciali né una decisione di riscrivere il motore.

Lettura dell'estensione: [evidenze e limiti](#12-evidenze-disponibili-e-limiti-del-profilo),
[hotspot concreti](#13-aree-concrete-su-cui-intervenire),
[scelta di C](#14-scelta-del-componente-nativo-c-come-primo-esperimento),
[piano delle prove](#17-piano-sperimentale-e-criteri-di-adozione).

## 1. Obiettivo e carico di lavoro

L'obiettivo è eseguire molte partite sullo stesso livello, con bot e strategie differenti.
Le statistiche comprendono momenti salienti, frequenza dei tiri ad effetto ed efficacia degli stili di gioco.
Strategia, avversario e meccanica di tiro introducono variabilità e rumore.
Le ottimizzazioni devono preservare questa variabilità e la validità delle statistiche.

La metrica principale è il numero di **partite statisticamente utili per euro**.
Il throughput assoluto e la latenza di una decisione sono metriche complementari.

Nella discussione, il tempo indicativo iniziale era 4–5 secondi per profilare un tiro.
L'interpretazione adottata è la valutazione della griglia dei candidati, non una singola traiettoria.
Questo valore proviene dalla conversazione e non da una nuova misura controllata.

Termini usati nel documento:

- **Candidato:** una specifica azione da simulare, per esempio un angolo di tiro.
- **Decisione:** la valutazione dei candidati e la scelta del tiro.
- **Partita:** una sequenza di decisioni e delle relative evoluzioni di stato.
- **Worker:** un esecutore con stato di simulazione e buffer propri.
- **Throughput:** la quantità di lavoro completata nell'unità di tempo.

## 2. Zero allocazioni, stack e heap

Zero allocazioni non significa che tutti i dati risiedano sullo stack.
Significa che il percorso misurato riutilizza memoria esistente, senza nuove allocazioni sull'heap.

Nel codice esaminato, gli stati persistenti includono strutture mutabili, vettori, dizionari e buffer riutilizzabili.
Gran parte di questi dati risiede sull'heap.
Julia può mantenere piccoli valori temporanei nei registri, usare lo stack oppure eliminarli durante la compilazione.
L'uso di strutture immutabili o di `StaticArrays` non garantisce da solo una collocazione sullo stack.

Il gate documentato riguarda lo **stepping caldo a capacità sufficiente**.
Reset, crescita iniziale dei buffer, estrazione dei risultati e diagnostica hanno contabilizzazioni separate.
Quindi il gate non implica zero allocazioni per l'intera campagna.
Il riferimento è [M4 performance gate](../benchmarks/m4-perf.md).

La distinzione utile è tra costo di allocazione e costo di accesso.
La cache può contenere dati dello stack e dell'heap.
Un array contiguo sull'heap può avere accessi molto efficienti.
Con allocazioni già eliminate dal percorso caldo, spostare i dati sullo stack non garantisce un miglioramento.

Le priorità sono ridurre i dati attraversati, gli accessi indiretti e il lavoro ripetuto.

## 3. Layout dei dati e geometria condivisa

### Situazione osservata

In `julia/PeggleSim/src/level.jl`, `Peg` è una struttura mutabile.
Contiene geometria, stato del peg, informazioni di linea e dati di scoring.
Un `Vector{Peg}` contiene riferimenti agli oggetti, anziché record geometrici consecutivi.

La fisica spesso usa soltanto una parte di questi campi.
Separare i dati frequenti dai metadati può ridurre accessi indiretti e traffico di memoria.

Due layout candidati sono:

- array separati per coordinate, raggi e altri campi, secondo il modello *structure of arrays*;
- array contigui di piccoli record immutabili, con i campi che la fisica legge insieme.

La scelta dipende dai pattern di accesso e richiede misure.

### Livello comune, progressi privati

Molte partite sullo stesso livello possono condividere una definizione geometrica in sola lettura.
Ogni partita conserva i propri progressi.

```text
Livello condiviso
├── geometria dei peg e identificatori stabili
├── metadati delle linee
├── trasformazioni geometriche invarianti
└── indice spaziale

Stato privato di ogni partita o simulazione candidata
├── peg presenti e stato dei peg
├── colori modificabili
├── palline, punteggio e poteri
├── stato RNG
└── buffer di lavoro
```

Soltanto i dati realmente invariabili appartengono alla parte condivisa.
Colori, posizioni o altri campi modificabili devono rimanere privati quando le regole li fanno evolvere.

Un indice privato dei peg presenti **non annulla la condivisione**.
Contiene identificatori o bit di presenza, non una copia completa della geometria.

Per 1.000 peg, una maschera compatta richiede circa 125 byte di soli bit.
Una lista completa di indici `Int32` richiede circa 4 KB di soli elementi.
Questi esempi escludono intestazioni, capacità aggiuntiva e gli altri campi dello stato.

### Indice spaziale comune e filtro privato

L'indice spaziale comune può produrre i peg vicini al movimento della pallina.
La maschera privata esclude i peg già eliminati nella specifica partita.
I test precisi operano sui peg rimasti, nell'ordine richiesto dalla fisica.

Verso la fine della partita, molti risultati dell'indice comune possono riferirsi a peg eliminati.
Una scansione della breve lista privata dei peg rimasti può allora risultare più economica.
Una strategia adattiva può scegliere tra indice comune e scansione privata.
La soglia di passaggio resta da misurare.

La geometria può servire sia molte partite sia molti candidati della stessa decisione.
Il reset di un candidato deve ripristinare lo stato dinamico, senza ricostruire la geometria invariabile.
Questo richiede una modifica strutturale rispetto al modello `Peg` esaminato.

## 4. Riduzione del lavoro della CPU

### Filtro geometrico e collisioni

La fisica separa già le forme e applica un filtro preliminare prima dei test costosi.
Le liste delle forme richiedono comunque scansioni.
Un indice spaziale può ridurre il numero di peg esaminati, soprattutto sui livelli densi.
Sui livelli piccoli, una scansione lineare può risultare migliore.

Il filtro deve essere conservativo rispetto a collisioni, tolleranze e graze.
L'ordine dei test, gli spareggi e gli aggiornamenti autorevoli devono preservare il comportamento esistente.
La riduzione dei controlli non deve introdurre approssimazioni nella fisica.

### Precalcolo e lookup

La geometria statica permette di riusare trasformazioni e quantità invarianti.
Il precalcolo deve preservare precisione e ordine delle operazioni rilevanti.
Un'identità matematica equivalente non garantisce gli stessi arrotondamenti floating-point.

I tracker contengono anche dizionari annidati e chiavi stringa.
Identificatori numerici interni e array indicizzati possono ridurre hashing e accessi indiretti.
Le stringhe possono rimanere nell'interfaccia esterna.

Queste sono ipotesi, non colli di bottiglia dimostrati.
Un profilo deve distinguere fisica, reset, eventi, estrazione dei risultati e scheduling.

## 5. Cache, affinità e NUMA

L'organizzazione tipica delle CPU moderne è la seguente.
I dettagli dipendono dal modello esatto.

| Livello | Organizzazione tipica |
| --- | --- |
| L1 e L2 | Private del core e condivise dai suoi thread SMT |
| L3 | Condivisa da un gruppo di core |
| RAM | Accessibile dai core, con possibili differenze di latenza NUMA |

Le cache private non rendono inutile una geometria condivisa.
Più core possono conservare copie degli stessi dati in sola lettura nelle proprie cache.
Queste letture non richiedono continue invalidazioni delle copie.

La condivisione riduce la duplicazione in RAM e può favorire il riuso nella cache condivisa.
Non garantisce però un aumento di throughput.
Se ogni worker trova già i dati importanti nella propria cache, il beneficio può essere modesto.

Su macchine NUMA, una copia della geometria per nodo può favorire accessi locali.
La condivisione logica non richiede quindi una sola copia fisica per l'intera macchina.

Altri aspetti da misurare sono:

- affinità CPU, per ridurre migrazioni dei worker;
- collocazione della memoria vicino ai worker che la usano;
- distribuzione del lavoro tra domini di cache;
- *false sharing*, quando worker diversi modificano dati nella stessa cache line.

Il bare metal offre controllo e maggiore prevedibilità.
Le ottimizzazioni di località restano utili anche sulle macchine condivise.
Layout compatto e accessi regolari precedono, come priorità, il prefetch manuale.

## 6. Multithreading e scheduling

Una singola traiettoria ha molte dipendenze temporali e rimane una buona unità seriale.
I candidati di una decisione sono invece lavori indipendenti.
La griglia documentata contiene 1.801 angoli.
Quindi 64 worker su una decisione non sono necessariamente sprecati.

La convenienza dipende dal costo dei candidati, dal loro sbilanciamento e dall'overhead dello scheduling.
Le traiettorie hanno durate differenti.
Una divisione rigida può lasciare molti core inattivi durante gli ultimi candidati lunghi.

| Obiettivo | Configurazione da confrontare |
| --- | --- |
| Throughput di campagna | Molte partite indipendenti, pochi worker per partita |
| Latenza di una decisione | Più worker sui candidati della stessa decisione |
| Compromesso | Pool comune con piccoli blocchi di candidati |

Le configurazioni 16 partite × 4 worker e 64 partite × 1 worker sono esempi sperimentali.
Nessuna delle due è una scelta definitiva.

Un pool persistente evita la ricostruzione continua dei motori e dei buffer.
Ogni worker possiede il proprio stato modificabile.
Blocchi di candidati limitano il costo di dispatch rispetto a un task per operazione o timestep.

Una preferenza per la stessa partita o checkpoint può favorire la località.
La redistribuzione del lavoro residuo può ridurre i tempi morti.
La dimensione dei blocchi deve bilanciare questi due effetti.

Il determinismo richiede stato e RNG indipendenti secondo la definizione dell'esperimento.
Ogni risultato occupa la posizione associata al suo candidato.
La scelta finale usa ordine e spareggi deterministici, non l'ordine di completamento.

Nel benchmark esaminato, `julia/PeggleSim/bin/shot_bench.jl` crea i motori dentro il passaggio parallelo cronometrato.
Questo passaggio non equivale a una campagna con worker persistenti.
Un nuovo scheduler deve considerare anche la migrazione dei task Julia.
La proprietà dello stato per worker/task è preferibile a un'associazione implicita basata soltanto su `threadid()`.

## 7. Riuso delle valutazioni tra bot

In teoria, bot diversi possono riusare risultati ottenuti dallo stesso identico stato e dagli stessi candidati.
Ogni bot può applicare una funzione di valutazione diversa alle caratteristiche risultanti.
L'identità richiesta comprende RNG, configurazione e ogni altro dato rilevante per la simulazione.
Lo stesso livello non basta.

Nel workflow previsto, rumore e strategie fanno divergere rapidamente gli stati.
Il riuso esatto può riguardare soprattutto il primo tiro e avere un beneficio limitato.
Questa opportunità non è una priorità.

Il riuso di un risultato realmente identico non altera da solo la distribuzione dell'esperimento.
Forzare traiettorie o casualità comuni per aumentare il riuso può invece introdurre correlazioni indesiderate.
La validità statistica prevale sul risparmio di calcolo.

## 8. SIMD e determinismo

### Operazioni indipendenti

SIMD esegue la stessa operazione su più elementi attraverso lane vettoriali.
Operazioni indipendenti possono conservare gli stessi risultati della versione scalare.

Per esempio, ogni elemento di `r[i] = a[i] * b[i] + c[i]` può mantenere moltiplicazione e somma separate.
Le condizioni rilevanti comprendono:

- stessa precisione e modalità di arrotondamento;
- stesso ordine delle operazioni per elemento;
- assenza di contrazione in FMA quando il riferimento usa operazioni separate;
- stesso comportamento dei casi speciali rilevanti.

Una riduzione, come la somma di molti elementi, presenta un problema diverso.
Il raggruppamento delle somme può cambiare gli arrotondamenti.
Anche le funzioni trascendenti vettoriali possono differire dalle funzioni deterministiche del progetto.

SIMD non implica necessariamente `fastmath`.
Il progetto vieta attualmente `@simd`, `@fastmath`, `muladd` e `fma` nel contratto documentato.
Un esperimento SIMD richiede una revisione esplicita del vincolo pertinente e una verifica della parità.
L'esame del codice generato completa i confronti dei risultati.

### Buffer globale di somme e moltiplicazioni

L'idea discussa prevede code condivise per operazioni aritmetiche.
Un esecutore SIMD svuota una coda quando raggiunge una capacità oppure scade un intervallo.

La soluzione è tecnicamente possibile, ma la granularità è troppo piccola per promettere un vantaggio.
Una somma o moltiplicazione su valori nei registri costa pochissimo.
La coda aggiunge scritture, sincronizzazione, attesa e lettura del risultato.
Il worker spesso richiede quel risultato prima di continuare.

Il buffer comune introduce inoltre contesa e traffico di coerenza tra core.
SIMD opera dentro un core, non come un acceleratore centrale accessibile senza costo.
Il timeout complica la latenza senza rendere gratuite le dipendenze.
La variazione del tempo di completamento non modifica necessariamente il risultato numerico.

### Kernel SIMD locali

L'alternativa promettente assegna a ogni worker un blocco di dati indipendenti.
Il worker esegue un kernel vettoriale locale, senza una coda globale per ogni operazione.

Un primo candidato è il filtro geometrico sui peg.
Ogni lane valuta un peg e produce un'indicazione di possibile contatto.
I test precisi elaborano poi i sopravvissuti nell'ordine originale.
Il filtro deve preservare collisioni, tolleranze e graze.

Un'alternativa più invasiva assegna una traiettoria a ogni lane.
Le traiettorie però divergono: alcune collidono, altre proseguono e altre terminano.
Servono maschere, gestione delle lane inattive e possibile ricompattazione.
Questo modello richiede una trasformazione importante del simulatore.

### Limite del guadagno complessivo

Il guadagno di un kernel non coincide con quello della campagna.
Se un kernel occupa il 40% del tempo, accelerarlo di quattro volte lascia il 70% del tempo originale.

```text
tempo relativo = 0,60 + 0,40 / 4 = 0,70
accelerazione complessiva ≈ 1,43×
```

L'esempio esclude overhead aggiuntivo e rappresenta un limite illustrativo, non una previsione per il simulatore.

## 9. Hardware e costo

EPYC, Xeon e Ryzen identificano famiglie, non prestazioni sufficientemente precise per una scelta.
Il confronto richiede modello, generazione, topologia e prezzo effettivo.

Una vCPU non equivale necessariamente a un core fisico dedicato.
Un'offerta da 64 vCPU può esporre 32 core con SMT o risorse virtuali con condizioni differenti.
I thread SMT condividono risorse e non raddoppiano automaticamente il throughput.

Una CPU ad alta frequenza può favorire la latenza delle decisioni.
Una CPU con molti core può favorire campagne con molte partite indipendenti.
Nessuna categoria garantisce il miglior rapporto tra throughput e costo.

Il confronto commerciale deve includere:

- modello esatto e numero di core fisici;
- significato delle vCPU offerte;
- risorse dedicate o condivise;
- domini di cache e topologia NUMA;
- prezzo, durata minima e costi accessori.

Questa discussione non comprende una ricerca di mercato o prezzi aggiornati.

## 10. Misure e ordine delle prove

Un benchmark rappresentativo deve eseguire molte partite sullo stesso livello.
Deve includere bot, rumore, raccolta delle statistiche e tutte le fasi della partita.
I worker persistenti devono rappresentare l'uso previsto in produzione.

La metrica economica di base è:

```text
partite per euro = partite completate per ora / costo della macchina per ora
```

Il confronto richiede lo stesso insieme di esperimenti, seed e regole di completamento.
I candidati al secondo aiutano la diagnosi, ma partite e strategie possono richiedere quantità diverse di lavoro.
Anche avvio, compilazione e preparazione incidono sul costo delle campagne brevi.

Sequenza proposta delle prove:

1. Definire il benchmark di campagna e i criteri di validità statistica.
2. Misurare separatamente fisica, reset, eventi, estrazione e scheduling.
3. Confrontare un worker per core fisico con l'uso dei thread SMT.
4. Confrontare più partite seriali con meno partite a candidati paralleli.
5. Misurare pool persistenti e dimensioni diverse dei blocchi di candidati.
6. Valutare indice spaziale, separazione della geometria e layout compatti dove il profilo ne indica l'utilità.
7. Misurare affinità, NUMA e kernel SIMD locali sulle macchine candidate.
8. Confrontare il throughput per euro prima di un noleggio prolungato.

Ogni modifica alla fisica richiede una verifica della parità deterministica.
Il tempo totale della campagna resta la misura finale del beneficio.

## 11. Conclusioni e questioni aperte

Le opportunità principali sono ridurre lavoro ripetuto, migliorare la località e distribuire bene i candidati.
La collocazione sullo stack non è una priorità rispetto a questi obiettivi.
La geometria condivisa resta compatibile con progressi privati e cache private.

Restano da misurare:

- il limite prevalente: calcolo, accessi alla memoria, branch, reset oppure scheduling;
- la dimensione dello stato caldo per worker;
- il vantaggio reale di un indice spaziale sui diversi livelli;
- il numero di worker per partita e la dimensione dei blocchi;
- il contributo di SMT, cache e NUMA;
- la convenienza di kernel SIMD con parità numerica;
- il miglior rapporto tra partite utili e costo sulle offerte disponibili.

Nessuna delle ipotesi discusse giustifica da sola una previsione di accelerazione elevata.
Il benchmark rappresentativo deve guidare sia l'architettura sia la scelta della macchina.

## 12. Evidenze disponibili e limiti del profilo

### 12.1 Provenienza

L'analisi usa il [notebook](../../notebooks/campaign_diagnostics.ipynb), il
[protocollo diagnostico](campaign-diagnostics.md) e soprattutto i dati del run
[`20261025T121437Z_omarchy_e49038`](../../results/diagnostics/runs/20261025T121437Z_omarchy_e49038/README.md).
Il manifest registra una sorgente non pulita alla revisione
`b7b987a6d93d2b8c5e7bfcc769f37297816bedf5`, con snapshot e hash dei file.
In questa revisione sono stati verificati l'hash dell'archivio e la
corrispondenza di tutti i file `src/*.jl` con lo snapshot misurato.
Il nome del run non va usato come sostituto della sua provenienza.

Il carico è composto da otto partite 1v1, 79 decisioni e 142.279 candidati
sul livello `ribbon_waves` da 133 peg. La macchina è un Ryzen 5 4600H:
sei core fisici, dodici CPU logiche, un nodo NUMA. Il backend matematico
misurato è `system_libm`. Tutti i trial e i warmup del run hanno lo stesso
hash di gameplay; questo prova la coerenza del confronto raccolto, non la
rappresentatività di ogni futuro bot o livello.

### 12.2 Che cosa è misurato

| Evidenza | Risultato | Interpretazione utile |
| --- | --- | --- |
| Campagna senza timer di fase | Mediana 149,514 s a un worker; 34,422 s a otto | Riferimento end-to-end su questo host, con tre ripetizioni per configurazione |
| Profilo CPU seriale | 13.813 campioni del thread principale | Localizza codice da investigare; non misura cicli, cache miss o banda RAM |
| Categorie esclusive | Fisica/collisioni 43,31%; broad phase 19,95%; scoring/eventi 18,72%; aggiornamenti 17,71% | Partizione secondo il classificatore dell'harness, con limiti dovuti a inlining e frame nativi |
| Allocazioni cumulative | Circa 2.017 MiB per campagna | Volume allocato durante il lavoro, non memoria residente simultanea |
| Tempo GC / wall time | Circa 0,16% a un worker e 1,2% a otto | Le sole pause GC non spiegano un potenziale vantaggio del 20% |
| Reset dei candidati | 1,37–1,47 s nei tre trial seriali con timer | Circa l'1% del wall time; ridurre le allocazioni del reset non promette da solo grandi guadagni seriali |

Le aggregazioni e i percorsi dei membri dell'archivio sono nel
[record di analisi](../../results/analysis/optimization-review-2026-10-25.json).
I tempi dei profiler non vengono usati come benchmark di throughput.

### 12.3 Precisazioni sulle conclusioni del notebook e del report

Il notebook è una buona mappa iniziale. Alcune interpretazioni del
[report derivato](../benchmarks/campaign-diagnostics.md) vanno però ristrette
prima di usarle come motivazione di una modifica:

- **Partecipazione agli stack e costo esclusivo sono diversi.** Il 37,41%
  di `check_annulars` è una quota di campioni dell'intera campagna in cui
  compare la funzione; include broad phase, matematica e funzioni chiamate.
  Non si somma al 19,95% della broad phase. Analogamente, i frame `det_*`
  comprendono il lavoro svolto nella libreria nativa chiamata.
- **La categoria `campaign_and_reset = 0,01%` non misura tutti i reset.**
  Il classificatore non riconosce direttamente `checkpoint.jl`; può
  attribuire quello stack al chiamante in `engine.jl`. Per questa domanda
  sono più pertinenti i timer `candidate_reset` e gli stack di `restore!`.
- **Gli style shot non possono essere omessi nei candidati attuali.**
  `evaluate_candidates!` legge `get_turn_score`, che include `e.style_score`;
  `apply_commands!` lo aggiorna con `award_style_points`. Saltare il tracking
  può cambiare punteggi, scelta dei tiri e distribuzione delle partite.
- **Non è dimostrato un limite di scalabilità del linguaggio.** Otto worker
  superano i sei core fisici e il batch contiene appena otto partite.
  Sbilanciamento, SMT, frequenza e contesa non sono stati isolati. Il limite
  illustrativo `sum(T_i)/max(T_i)` assume costi invarianti e riguarda quel
  batch finito, non una lunga coda di partite.
- **Le righe RSS non misurano byte per worker o working set caldo.**
  Sono processi distinti, con runtime, compilatore e strumenti diagnostici
  caricati. Non giustificano una stima lineare di memoria incrementale per
  worker, né dimostrano pressione sulle cache della fisica.
- **Il backend qualificato qui non è CORE-MATH.** Il
  [contratto matematico](../decisions/0001-math-backend.md) conserva
  `system_libm` come riferimento Linux e `core_math` come backend
  sperimentale. Approssimazioni trigonometriche non sono un'ottimizzazione
  equivalente del comportamento corrente.

Non sono ancora disponibili contatori hardware, tempi sulla macchina da
noleggiare, un profilo CPU parallelo o un confronto tra kernel Julia e C/Odin.

## 13. Aree concrete su cui intervenire

### 13.1 Prima prova: l'indice temporaneo degli eventi di scoring

**Evidenza.** In [style_shots.jl](../../julia/PeggleSim/src/style_shots.jl),
`style_shots_process!` esegue a ogni passo `empty!(scored_by_source)`.
Il dizionario è `Dict{Int,GameEvent}` e associa la sequenza dell'evento raw
all'evento derivato `peg_scored`. La riga 485 dello snapshot compare in
2.023 campioni su 13.813: **14,65% del totale**. Molti stack proseguono in
`empty!`, `_unsetindex!` e nell'iterazione interna della memoria.
Questa è un'indicazione più specifica del generico «style shot costosi».

In Julia 1.12.6, `empty!(::Dict)` azzera gli slot e visita la capacità delle
memorie di chiavi e valori. Il lavoro non dipende soltanto dal numero di
elementi attivi; anche un dizionario già vuoto può ripetere la pulizia.
Il [sorgente della versione usata](https://github.com/JuliaLang/julia/blob/v1.12.6/base/dict.jl)
conferma questo percorso. `GameEvent` contiene inoltre il payload composito
`EventFields`, con riferimenti: «zero allocazioni» non significa «costo
trascurabile per svuotare il contenitore».

**Esperimenti in ordine di invasività:**

1. Misurare in una diagnostica separata frequenza della pulizia, elementi
   attivi e capacità dopo il warmup; provare una guardia `isempty` prima
   della pulizia quando il contenitore è già vuoto.
2. Sostituire i valori `GameEvent` con indici interi in `journal.derived`,
   conservando la semantica dell'ultima assegnazione per la stessa chiave.
3. Valutare un vettore indicizzato dalla sequenza raw del passo, che riparte
   da uno, con zero come assenza. Ripulire solo le posizioni toccate oppure
   usare generazioni, gestendone l'overflow. Gli eventi restano nel journal.

L'accesso all'evento tramite indice deve avvenire mentre il journal è valido;
nessun indice deve sopravvivere al reset del passo. L'ordine raw/derived e i
comandi di scoring restano identici. Il test pertinente include slide,
rimbalzi, più contatti nello stesso passo e ripetizione di reset.

**Giudizio.** È la prima prova consigliata: evidenza specifica, modifica
circoscritta, nessuna necessità di C. Il 14,65% è attribuzione campionata,
non un risparmio già ottenuto né una frazione eliminabile integralmente.

### 13.2 Broad phase: eliminare matematica ripetuta prima di vettorizzare

**Evidenza.** In [physics.jl](../../julia/PeggleSim/src/physics.jl),
`broad_phase_common` calcola la lunghezza dello spostamento relativo con
`det_sqrt` per ogni peg visitato. Per peg statici, lo spostamento relativo
è comune alla finestra corrente di movimento della stessa pallina.
Negli stack della broad phase, 1.048 campioni hanno come frame di progetto
più profondo la chiamata `system_libm` di `det_sqrt`: il 7,59% del totale.
È un sottoinsieme della broad phase, non una quota aggiuntiva.

**Esperimento.** Preparare una query per la finestra CCD corrente:
spostamento relativo statico, sua lunghezza e dati della pallina. Riutilizzarla
nelle scansioni dei peg immobili, mantenendo la stessa espressione e lo
stesso backend per il calcolo condiviso. Verificare separatamente gli zeri
con segno e le condizioni del percorso statico.

La query va aggiornata dopo ogni collisione che modifica movimento o tempo
residuo; non basta prepararla una volta per tiro o timestep. I peg mobili,
i divider e le collisioni tra palline devono seguire il percorso appropriato.
L'attuale loader accetta livelli statici, ma i kernel contengono anche
logica di movimento che non va eliminata indiscriminatamente.

Il raggio di bounding, oggi memorizzato pigramente nel `Peg` e perso quando
il reset ricrea gli oggetti, può essere preparato con la geometria. Anche
`depenetrate` ricalcola il raggio dei rettangoli: è un altro uso da esaminare.

**Giudizio.** Priorità alta in Julia. Un port letterale in C che ripeta le
stesse radici per ogni peg non risolve il problema strutturale.

**Implementazione del 27 ottobre 2026 (§17.1, punto 2).**
`StaticCollisionQuery` conserva spostamento relativo e lunghezza per la
finestra CCD corrente; viene ricostruita nel ciclo delle collisioni, dopo
l'aggiornamento di movimento e tempo residuo. La query è privata del worker.
Solo velocità traslazionali `+0.0` usano il percorso condiviso; velocità
mobili e `-0.0` conservano il calcolo originale. Anche la preparazione usa
`move - 0.0 * time_remaining`, senza eliminare la sottrazione. I divider
statici riutilizzano la query, mentre collisioni tra palline e slicing
rotazionale mantengono i propri percorsi.

Il raggio dei rettangoli viene calcolato nel costruttore della forma
immutabile con la stessa espressione e lo stesso backend; i peg ricreati
dal reset lo riutilizzano. Broad phase e depenetrazione leggono il raggio
preparato. Il formato serializzato dei checkpoint non cambia.

La campagna Deathstar di dieci partite ha misurato 145,948 s contro i
180,029 s del run salvato, con sorgenti del baseline equivalenti al commit
corrente: tempo −18,93%, throughput +23,35%, storie canoniche byte-identiche.
È un confronto tra due singoli trial, senza stima della variabilità.
[Report e protocollo](../../results/analysis/static-query-optimization-2026-10-27.json);
[verifiche e implementazione](../devlog/2026-10-27.md#shared-static-ccd-query-171-experiment-2).

### 13.3 Archi e rettangoli: geometria preparata e filtri conservativi

**Evidenza.** `check_annulars` calcola seno e coseno degli estremi dell'arco;
`annular_check_cap` e `annular_check_corner` li richiamano per gli stessi
angoli. I quattro corner condividono due angoli e due raggi. Anche
`surface_separation` in
[impact_geometry.jl](../../julia/PeggleSim/src/impact_geometry.jl) usa
trasformazioni geometriche. Il profilo rende rilevante questo percorso,
ma non misura separatamente tutti questi ricalcoli.

Per la geometria immutabile preparare, dove applicabile:

- seno/coseno degli angoli effettivamente usati, normali delle cap e corner;
- mezze dimensioni, raggi di bounding e prodotti invarianti;
- bounding box conservativi degli archi reali, non soltanto del cerchio
  completo di raggio esterno.

Il precalcolo deve riprodurre gli stessi argomenti e le stesse operazioni.
Una formula equivalente o `sincos` non è automaticamente bit-identica a
due chiamate separate. I valori dipendenti da posizione/rotazione viva
richiedono invalidazione o il percorso generico. La geometria preparata
deve essere legata anche all'identità del backend matematico.

Un bounding box più stretto può evitare corner, cap e test angolari
costosi. Deve includere il movimento spazzato, il raggio della pallina,
graze, tolleranze e tutti i casi di overlap rilevanti. Il criterio di
correttezza è **nessun falso negativo**, non soltanto lo stesso primo urto
sui casi facili.

Come primo esperimento, aggiungere il filtro prima dei controlli esistenti.
Un filtro più permissivo non deve introdurre contatti che il percorso
originale scartava: conservare anche la decisione del vecchio filtro finché
non è dimostrata l'equivalenza della sua sostituzione. La parità riguarda
il comportamento congelato, non una diversa interpretazione della fisica.

Non sostituire inizialmente `atan2` con confronti di prodotti vettoriali:
gli arrotondamenti vicino ai limiti dell'arco possono cambiare le decisioni.
Prima ridurre quante volte si entra nel test preciso.

**Giudizio.** Priorità alta per precalcoli e filtri in Julia; buon candidato
per una successiva estensione del kernel C, dopo aver isolato i benefici.

### 13.4 Layout, reset e indice spaziale

In [level.jl](../../julia/PeggleSim/src/level.jl), `Peg` mescola geometria,
stato di scoring, metadati e campi di movimento; le liste per forma
contengono riferimenti a questi oggetti. Il layout da provare è una
geometria preparata, separata per forma, con record numerici compatti oppure
SoA, e stato dinamico privato indicizzato. La sola immutabilità non basta:
per un array numerico inline Julia occorrono record adatti, senza stringhe
o altri riferimenti interni. I metadati esterni possono restare separati.

Per il reset, [checkpoint.jl](../../julia/PeggleSim/src/checkpoint.jl)
ricrea i `Peg`, ricostruisce indici e decodifica lo stato RNG Base64 per
ogni candidato. I primi due siti del profilo di allocazione, `Peg` e RNG,
pesano circa il 90% dei **byte campionati**. Le prove utili sono:

- riusare gli oggetti o copiare lo stato in buffer numerici già allocati;
- preparare una rappresentazione interna del checkpoint una volta per
  decisione, con stato RNG decodificato completo;
- conservare formato, hash e serializzazione del checkpoint esterno;
- ricostruire correttamente riferimenti, liste per forma e tracker dopo
  eliminazioni di peg, spawn e reset ripetuti.

Questo lavoro è utile anche per il confine nativo, ma il costo seriale
misurato del reset è circa l'1%. Non giustifica la promessa di un grande
guadagno di throughput. Il beneficio di località durante il tiro o di
scalabilità su molti core rimane da misurare. Anche l'eliminazione del
90% delle allocazioni lascerebbe indicativamente circa 200 MiB, non
dimostrerebbe l'obiettivo «meno di 100 MiB» del report precedente.

L'indice spaziale va confrontato con una scansione compatta sul livello
reale da 133 peg, non soltanto su scene artificialmente enormi. Misurare
peg visitati, sopravvissuti al filtro, test precisi e costo della query.
Per griglie/BVH includere deduplicazione e ricostruzione dell'ordine.
Quando rimangono pochi peg, può vincere la lista compatta privata.

**Vincoli poco visibili ma decisivi:**

- `register_hit!` usa priorità e **indice nella lista corrente per forma**
  per gli spareggi; non basta restituire un insieme di ID stabili.
- Confronti entro `toi_epsilon` richiedono di preservare l'ordine del
  procedimento. Una riduzione parallela al minimo non è equivalente per
  definizione.
- `depenetrate` aggiorna la posizione della pallina durante la scansione.
  Un filtro calcolato una sola volta sulla posizione iniziale potrebbe
  escludere un peg diventato rilevante dopo una correzione precedente.

### 13.5 Eventi e aggiornamenti oltre il primo hotspot

Dopo aver affrontato `scored_by_source`, riprofilare prima di convertire
tutti i tracker. Ulteriori candidati sono ID numerici per linee e tipi di
evento, mappe per pallina più compatte e indici ai payload invece di copie.
L'attuale `EventFields` superset ha eliminato allocazioni nel percorso
caldo; una sua sostituzione deve evitare di reintrodurre boxing o perdere
la proprietà dei dati. Un contenitore specializzato può aiutare anche
interamente in Julia.

`save_previous_state` compare in 522 campioni (circa 3,8%) e attraversa
tutti i peg a ogni passo. La componente statica merita una misura separata,
ma non va soppressa soltanto perché descritta come interpolazione grafica:
occorre verificare tutti i lettori di `prev_*`, le tracce e il contratto
che vieta di omettere aggiornamenti autorevoli. Questa prova è successiva
alle ottimizzazioni che preservano direttamente la pipeline.

### 13.6 Scheduling: rappresentare una lunga campagna sul server

In [campaign.jl](../../julia/PeggleSim/src/campaign.jl), `run_campaign`
crea un task per worker e assegna le partite con
`worker:workers:o.games`. Con otto partite e otto worker questo coincide
con un task per partita; con molte partite è una ripartizione statica.
Ogni partita crea un motore live e uno candidate, riutilizzati nei turni
di quella partita. Non esiste ancora un pool di motori riusato tra partite.

Per il costo di una campagna lunga, confrontare prima molte più partite
dei worker e una coda dinamica di partite con seed assegnati agli ID prima
dello scheduling. Conservare gli output nell'ordine degli ID. Con tante
partite indipendenti si può mantenere occupata la macchina senza introdurre
parallelismo dentro ogni decisione.

Passare ai blocchi di candidati se rimangono tempi morti significativi,
se il batch reale è piccolo oppure se serve ridurre la latenza della
decisione. Misurare distribuzione delle durate, occupazione dei worker,
costo del dispatch e reset aggiuntivi. Evitare pool annidati che moltiplicano
i thread. La proprietà dei buffer segue il worker logico/task; non
presumere che `threadid()` sia costante, come avverte la
[documentazione Julia](https://docs.julialang.org/en/v1/manual/multi-threading/#Task-Migration).

L'identità RNG deve dipendere dall'esperimento e dal candidato, mai
dall'ordine di completamento. Una prova con tante partite ripetute può
servire per la saturazione, ma non trasforma seed duplicati in nuove
osservazioni statisticamente indipendenti.

## 14. Scelta del componente nativo: C come primo esperimento

### 14.1 Che cosa offre davvero il cambio di linguaggio

Julia compila codice macchina attraverso LLVM; questo non rende il suo
output identico a quello di Clang o Odin. Tipi inferiti, aliasing, layout,
controlli, chiamate al runtime e semantica floating-point influenzano le
ottimizzazioni. Per un kernel numerico ben strutturato Julia può già
produrre codice efficiente. Occorre ispezionare il caso concreto, non
assumere né equivalenza perfetta né una penalità fissa.

| Strategia | Julia | C | Odin |
| --- | --- | --- | --- |
| Geometria numerica contigua/SoA | Array di record adatti o array separati | Layout esplicito | Layout esplicito e supporto `#soa` |
| Buffer persistenti | Preallocazione; attenzione a crescita e oggetti referenziati | Ownership e allocatori espliciti | Ownership e allocatori espliciti |
| SIMD locale | Autovettorizzazione o strumenti specifici, da qualificare | Autovettorizzazione e intrinsics | Tipi SIMD e intrinsics |
| Indice spaziale/precalcoli | Stessi algoritmi applicabili | Stessi algoritmi applicabili | Stessi algoritmi applicabili |
| NUMA/affinità | Configurazione esterna o API native | Accesso diretto alle API | Accesso alle API esterne |
| Esperimenti, bot e orchestrazione | Già implementati nel progetto | Da mantenere separati o riscrivere | Da mantenere separati o riscrivere |

Il criterio economico resta il tempo totale del workload. Allocatori
manuali, SIMD o assenza di JIT non sono di per sé misure di throughput.

### 14.2 Perché investigare prima C

La raccomandazione è una **piccola libreria C con ABI esplicita**, mantenendo
in Julia campagne, bot, RNG, scoring e pipeline del motore. Le ragioni
specifiche del progetto sono:

1. [detmath.jl](../../julia/PeggleSim/src/detmath.jl) usa già `ccall` per
   `system_libm` e per il componente CORE-MATH. L'interoperabilità nativa
   non richiede una nuova infrastruttura concettuale.
2. Esistono già [header](../../native/peggle_math.h),
   [build riproducibile](../../native/build.sh), identità del binario e
   controlli sui simboli. Si possono riusare le convenzioni per una libreria
   di kernel separata, senza modificare l'ABI matematica congelata.
3. C espone direttamente buffer, `size_t`, tipi a larghezza fissa,
   allineamento e intrinsics. Non serve introdurre un ecosistema di
   dipendenze ampio per un filtro geometrico.
4. Si possono confrontare Clang e GCC sullo stesso sorgente e controllare
   vettorizzazione, assembly e opzioni numeriche. Questo rende investigabile
   anche un eventuale limite del compilatore, distinto dal layout.

La documentazione Julia descrive chiamate a librerie C e gestione dei
buffer direttamente tramite `@ccall`/`ccall`, senza un binding generator
obbligatorio. [Interfaccia Julia/C](https://docs.julialang.org/en/v1/manual/calling-c-and-fortran-code/).

«C è ineguagliabile con l'hardware» non è una previsione verificabile per
questo carico. Qui C è una scelta pratica per controllare e misurare il
kernel, non una garanzia di vincere il confronto.

### 14.3 Odin rimane compatibile con la stessa architettura

Odin può esportare una shared library con funzioni `@(export)` e convenzione
`proc "c"`; la compilazione usa `-build-mode:dll`. Julia può chiamare quella
ABI come qualsiasi altra libreria C. La fattibilità deriva dai due
meccanismi documentati; non è stato compilato un prototipo Odin in questa
analisi. [Esempio ufficiale di libreria Odin](https://odin-lang.org/news/calling-odin-from-python/).

La convenzione predefinita Odin passa un contesto implicito: non va confusa
con l'ABI C. Buffer e lunghezze esplicite evitano di esporre slice, mappe o
contenitori Odin come contratto binario. Il contesto va gestito se il
codice esportato usa servizi che lo richiedono. SoA, SIMD e allocator sono
vantaggi espressivi pertinenti. [Convenzioni e tipi Odin](https://odin-lang.org/docs/overview/).

Odin diventerebbe una prova utile se il componente nativo crescesse e la
sua struttura rendesse sensibilmente più semplice mantenere layout e
kernel. Oggi non c'è evidenza che produca codice più veloce del C per la
porzione proposta. L'ABI comune permette di aggiungerlo in seguito allo
stesso benchmark senza cambiare il motore Julia.

### 14.4 Assembler e matematica nativa già esistente

Il repository contiene già un caso circoscritto di assembly:
[`native/sqrt_shim.c`](../../native/sqrt_shim.c), usato dal componente
CORE-MATH per controllare la risoluzione di `sqrt`. Non è una prova che
trasferire altre operazioni in assembly acceleri la campagna `system_libm`.

Le chiamate `det_sin`, `det_cos` e `det_sqrt` del run sono già chiamate
native. Spostare soltanto il wrapper in C non rende più veloce la stessa
funzione di libm. Le opportunità sono evitare chiamate ripetute, preparare
invarianti o dimostrare un'alternativa numericamente equivalente.
Sostituire libm con istruzioni hardware o approssimazioni è una prova
distinta, con gli stessi requisiti di parità e una qualificazione esplicita.

Assembly manuale va considerato solo dopo aver dimostrato un limite nel
codice generato che gli intrinsics non risolvono, e un effetto misurabile
sulla campagna. Richiede una variante per architettura e un fallback.

## 15. Primo confine Julia/C e contratto di correttezza

### 15.1 Kernel proposto: filtro statico per blocchi di peg

Il primo prototipo nativo dovrebbe filtrare un blocco di peg statici per
una singola query di movimento, lasciando in Julia i test precisi e la
riduzione ordinata dei contatti. È più semplice da qualificare rispetto a
un port completo di `physics_update!` e offre operazioni indipendenti per
lane. La query incorpora il lavoro condiviso di §13.2.

```text
Julia: campagna, bot, worker, stato e query CCD
                 │
                 │ geometria numerica preparata + query
                 ▼
        filtro Julia oppure filtro C
                 │
                 │ maschera per posizione nella lista
                 ▼
Julia: test precisi in ordine → contatti → scoring → scelta del tiro
```

Input: coordinate, bounding radius o bounds conservativi, presenza dei peg,
lunghezza dei buffer e query scalare. Output: un buffer riutilizzabile di
byte 0/1, associato alle posizioni originali. Per un primo confronto,
evitare la complicazione di una lista compressa o di bit condivisi.
I sopravvissuti vengono elaborati nello stesso ordine della versione attuale.

La geometria si prepara una volta per livello; lo stato modificabile e le
liste attive si aggiornano ai confini appropriati. Non convertire
`Vector{Peg}` in SoA a ogni chiamata. La query si ricostruisce quando cambia
la finestra di movimento. Un kernel di soli filtri può perdere su blocchi
piccoli a causa della chiamata, del buffer di output e della scansione
successiva: il livello da 133 peg è quindi una prova essenziale.

Una seconda fase può includere test precisi per forma, purché restituisca
tutti i fatti necessari, compresi graze e ordinamento. Non basta restituire
il solo tempo minimo di urto. Va preservata anche la dipendenza da
`ctx.min_t` nei percorsi che interrompono la scansione delle slice.

### 15.2 Regole dell'interfaccia proposta

- Usare un header versionato, lunghezze esplicite e tipi numerici C
  corrispondenti ai tipi Julia. Definire base degli indici, validità dei
  buffer e associazione agli ordinali delle liste. Non passare direttamente
  `Peg`, `GameEvent`, stringhe o layout interni del GC.
- Preferire memoria di input/output posseduta da Julia e prestata per la
  durata della chiamata sincrona. Quando si estraggono puntatori o li si
  inserisce in descrittori, mantenere vivi gli owner con `GC.@preserve`.
  Il codice nativo non conserva puntatori dopo il ritorno.
- Nessuna allocazione, callback verso Julia o creazione di thread nel
  percorso del filtro. Worker diversi ricevono scratch distinti.
  Se in futuro C alloca memoria NUMA, esportare anche la distruzione con
  lo stesso allocator e definire esplicitamente il ciclo di vita.
- Allineamento e assenza di alias devono essere garantiti oppure verificati.
  `restrict` è una promessa del chiamante, non un suggerimento innocuo.
  Usare accessi non allineati se non si possiede una garanzia più forte.
- Controllare capacità dell'output e input non validi al confine; usare
  codici di errore espliciti. Non affidarsi a comportamento indefinito per
  ottenere vettorizzazione.

Queste sono scelte progettuali proposte. La gestione degli owner e delle
allocazioni deve rispettare le regole di
[interoperabilità Julia](https://docs.julialang.org/en/v1/manual/calling-c-and-fortran-code/#Memory-Ownership).

### 15.3 Numerica, SIMD e compilazione

Il kernel deve conservare precisione `Float64`, ordine delle operazioni
per elemento, confronti, tolleranze e trattamento dei casi speciali
rilevanti. Non usare `-ffast-math` o `-Ofast`. Disabilitare esplicitamente
la contrazione FMA: per Clang `-fno-fast-math` da solo non equivale a
`-ffp-contract=off`. Registrare la combinazione effettiva di opzioni, il
backend matematico e l'ISA. [Opzioni floating-point Clang](https://clang.llvm.org/docs/UsersManual.html#controlling-floating-point-behavior).

Il contratto corrente vieta `@simd`, `@fastmath`, `@turbo`, `muladd` e `fma`
nel percorso autorevole. Un esperimento SIMD nativo non deve essere un
modo di aggirare il contratto: richiede una revisione esplicita del vincolo
pertinente, conservando il requisito di parità. SIMD senza riduzioni né
riassociazione può essere compatibile, ma va dimostrato nel kernel concreto.

Ispezionare `@code_warntype`, `@code_llvm` e `@code_native` per le firme Julia
effettive; per C conservare assembly e report di vettorizzazione. Clang
offre `-Rpass`, `-Rpass-missed` e `-Rpass-analysis` per `loop-vectorize`.
[Diagnostica LLVM](https://llvm.org/docs/Vectorizers.html#diagnostics).
Una funzione marcata `@inline` non prova che la chiamata libm sia stata
inlined; l'assenza di annotazioni SIMD non prova assenza di vettorizzazione.

Il binario di base deve funzionare sull'ISA dichiarata. Varianti AVX2 o
altre estensioni si selezionano su capacità effettivamente disponibili,
con fallback. Non distribuire un build `-march=native` senza registrare
quale macchina e quali istruzioni presuppone. Per confrontare Julia e C,
allineare quanto possibile il target CPU e documentare le differenze.

## 16. NUMA, prefetch e contatori hardware: quando hanno senso

### 16.1 NUMA è una scelta di collocazione, non un linguaggio

Il run locale ha un solo nodo NUMA: non può dimostrare un beneficio da
collocazione multinodo. Sul server raccogliere topologia reale, cpuset,
domini di cache, SMT e disponibilità di contatori prima di scegliere la
configurazione. Una VM può non esporre tutte le informazioni utili.

Confrontare un processo Julia multithread con più processi assegnati a
nodi NUMA, distribuendo partite complete e aggregando statistiche fuori dal
percorso caldo. I processi separati replicano runtime, warmup e parte dei
dati, ma possono semplificare località e isolamento. Evitare di moltiplicare
processi per core senza misurare memoria e costo di avvio.

`numactl` consente di impostare binding CPU e politica di memoria per
un processo già esistente come programma, senza riscriverlo in C.
[Manuale numactl](https://github.com/numactl/numactl/blob/master/numactl.8).
Per politiche più fini si possono usare API native e un wrapper piccolo.

La collocazione delle pagine va coordinata con inizializzazione e worker:
vincolare un thread dopo che un altro ha già materializzato tutte le
pagine non le sposta automaticamente. Le policy possono avere ambito per
thread o per mapping; le pagine già allocate richiedono considerazioni
separate, e i cpuset limitano i nodi utilizzabili.
[Politiche NUMA Linux](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html).

Buffer indipendenti e grandi possono giustificare un allocator nativo
locale al nodo. I piccoli oggetti del GC non sono un buon confine iniziale
per un controllo pagina per pagina. Provare una copia della geometria per
nodo solo quando la località porta un beneficio misurato.

### 16.2 Prefetch manuale dopo una diagnosi di attesa della memoria

Il profilo Julia non dimostra che il simulatore sia limitato dalla RAM.
Un algoritmo con molti branch, chiamate libm e oggetti piccoli può essere
limitato da cause diverse, anche quando usa heap e puntatori.

Prima compattare i dati ed eliminare lavoro ripetuto. Se restano attese
di memoria e gli indirizzi futuri sono prevedibili, sperimentare il
prefetch **dentro il ciclo che consuma i dati**. Il builtin C può anticipare
accessi quando la distanza temporale è sufficiente; non sostituisce una
misura. [GCC `__builtin_prefetch`](https://gcc.gnu.org/onlinedocs/gcc/Other-Builtins.html).

Confrontare distanza di anticipo, dimensione dei blocchi e assenza di
prefetch. Più traffico e dati inutili possono peggiorare cache e banda.
Validare il beneficio con tutti i core occupati, non soltanto in un
microbenchmark seriale. Chiamare C da Julia per ogni singolo prefetch
introdurrebbe un confine troppo fine.

### 16.3 Misure che mancano

| Domanda | Misura diagnostica | Decisione che può informare |
| --- | --- | --- |
| Stiamo facendo troppo lavoro? | Istruzioni, cicli, chiamate matematiche e peg visitati per candidato | Precalcolo, indice spaziale, percorsi specializzati |
| Il limite è memoria o controllo? | Miss di cache/TLB, branch miss e metriche specifiche della CPU | Layout, filtri, prefetch; nessun singolo contatore basta |
| I core restano inattivi? | Tempo occupato per worker, coda, coda finale del batch, migrazioni | Più partite, scheduling dinamico, blocchi di candidati |
| La memoria è remota? | Collocazione delle pagine e contatori NUMA disponibili | Binding, inizializzazione locale, processi per nodo |
| SIMD migliora il server intero? | Throughput a pieno carico, frequenza, consumo di banda | Larghezza vettoriale e numero di worker |

Usare `perf stat`/sampling su una regione riscaldata e identificabile;
misurare l'intero avvio Julia mescolerebbe compilazione e simulazione.
Registrare eventi disponibili e percentuale di tempo realmente misurata,
evitando troppi contatori simultanei: il multiplexing può distorcere
confronti tra fasi diverse. [perf stat](https://github.com/torvalds/linux/blob/master/tools/perf/Documentation/perf-stat.txt),
[gruppi di eventi](https://github.com/torvalds/linux/blob/master/tools/perf/Documentation/perf-list.txt).
Le prove con profiler o contatori restano separate dai trial di throughput.

## 17. Piano sperimentale e criteri di adozione

### 17.1 Ordine consigliato

| Ordine | Esperimento | Variante iniziale | Evidenza per continuare |
| --- | --- | --- | --- |
| 1 | Pulizia e rappresentazione di `scored_by_source` | Julia, prima guardia poi indici | Meno lavoro nel sito identificato, punteggi identici e miglioramento della campagna |
| 2 | Query statica condivisa e precalcoli geometrici | Julia | Meno chiamate ripetute e parità di contatti/tracce |
| 3 | Saturazione con molte partite e SMT | Julia, macchina candidata | Più partite/ora a costo invariato, senza cambiare esperimenti o seed |
| 4 | Geometria compatta e checkpoint preparato | Julia | Migliore tempo totale/località o memoria; distinguere l'effetto dal solo calo di allocazioni |
| 5 | Filtro per blocchi a layout equivalente | Julia e C | Beneficio nativo residuo, compresi chiamata e gestione dei buffer |
| 6 | Indice spaziale o filtri più stretti | Prima Julia, poi stesso algoritmo C se utile | Vantaggio su scene dense e assenza di regressioni importanti su scene sparse |
| 7 | SIMD qualificato, affinità e NUMA | Kernel C e configurazione del server | Beneficio a pieno carico sul modello CPU reale |
| 8 | Prefetch o assembly mirato | Solo dopo diagnosi hardware | Vantaggio ripetibile oltre le versioni precedenti |

La prova di saturazione sul server può procedere indipendentemente dalle
modifiche ai kernel. L'ordine delle altre prove va aggiornato dopo ogni
nuovo profilo: rimuovere un hotspot cambia il peso relativo degli altri.

### 17.2 Confronto che separa layout, algoritmo e linguaggio

Per il filtro usare almeno quattro varianti:

1. baseline Julia corrente;
2. Julia con invarianti/layout migliorati;
3. Julia con lo stesso confine a blocchi e buffer previsto per C;
4. C con identico algoritmo, input, layout e contratto numerico.

La terza variante misura anche il costo di separare filtro e consumo dei
risultati: senza di essa si rischia di attribuire al linguaggio il costo
del nuovo confine. Odin può aggiungersi come quinta variante con la stessa
ABI se emerge un motivo concreto. Registrare preparazione, copia eventuale,
chiamata, filtro, consumo dell'output e tempo totale; confrontare anche la
baseline monolitica, che può beneficiare di inlining e fusione dei cicli.

Il corpus del kernel deve provenire dal motore: finestre CCD dense/sparse,
tiri brevi/lunghi, contatti tangenti, overlap, multiball e casi sulle
tolleranze. Campioni estratti da una stessa partita non sono repliche
statistiche indipendenti del benchmark.

### 17.3 Gate prima di parlare di risparmio

- Congelare sorgenti, configurazione, seed, toolchain, backend matematico,
  hash delle librerie, target CPU e condizioni della macchina. Per ogni
  sessione di misura eseguire `make verify` prima e dopo.
- Verificare maschere/risultati del kernel e casi di bordo, poi fixture,
  tracce byte-identiche, sweep completi, checkpoint/reset e parità tra
  seriale e parallelo. Lo stesso vincitore non basta: confrontare anche
  punteggi dei candidati, graze, RNG e ordinamento degli eventi.
- Eseguire i gate pertinenti del quickstart: test Julia, M3/M4, corpus
  ribbon/campagna e allocazioni. Per C aggiungere verifica ABI e diagnostica
  di accessi fuori limite/lifetime su build dedicati; non cronometrare i
  build strumentati come produzione.
- Misurare trial end-to-end senza profiler, con warmup dichiarato, ordine
  delle varianti alternato o randomizzato e più ripetizioni quando la
  differenza è vicina alla variabilità. Riportare dispersione e metodo,
  non soltanto il migliore dei trial.
- Conservare il batch storico per la regressione e aggiungere un protocollo
  distinto di campagna sostenuta: molti più game dei worker, livelli e bot
  rappresentativi, pieno carico, core fisici e SMT. Non reinterpretare
  retroattivamente i risultati del batch da otto partite.
- Richiedere il miglioramento sull'intera campagna e sul server candidato.
  Un microbenchmark positivo con campagna invariata è informazione utile,
  ma non dimostra un risparmio di noleggio.

Nessuna di queste prove comparative è già stata eseguita da questa analisi.
L'harness esistente fornisce una base; prove ABI, kernel e carico sostenuto
andranno aggiunte quando si implementano le rispettive varianti.

## 18. Budget di accelerazione e decisione economica

Con quota di tempo `p` interessata e accelerazione locale `s`, in assenza
di altri effetti il tempo relativo diventa `1 - p + p/s`. È un modello per
dimensionare gli esperimenti, non una previsione tratta dai campioni CPU.

| Quota `p` illustrativa | Accelerazione locale | Throughput complessivo |
| --- | --- | --- |
| 20% | 2× | Circa +11,1% |
| 20% | 4× | Circa +17,6% |
| 40% | 1,2× | Circa +7,1% |
| 40% | Circa 1,71× | Circa +20% |

Per una modifica che acceleri **solo** la broad phase, la quota campionata
del 20% suggerisce un tetto illustrativo vicino a 1,25× se il resto
rimanesse identico. Un indice o un layout che riduca anche lavoro nei
test precisi può avere un effetto più ampio: il tetto non si applica
automaticamente a tutte le modifiche della geometria. Anche reset,
cache e scheduling possono interagire; non sommare percentuali di
guadagno osservate separatamente.

Per lavoro fisso e costo orario invariato:

```text
accelerazione complessiva = S
costo di esecuzione nuovo / costo attuale = 1 / S
risparmio relativo = 1 - 1 / S
```

Quindi +20% di throughput significa circa 16,7% di costo in meno, con
fatturazione proporzionale al tempo. Se il noleggio mensile rimane comunque
necessario, significa più risultati nello stesso periodo; il risparmio
monetario arriva quando si può ridurre durata o numero delle macchine.
Includere memoria richiesta, warmup ripetuti, output e costi accessori nel
confronto delle offerte. Nessun prezzo corrente è assunto qui.

Con costo incrementale del componente nativo `D` e budget di esecuzione
residuo `B`, un criterio semplificato di pareggio è
`B × (1 - 1/S) > D`, includendo in `D` qualificazione e manutenzione.
Se l'esecuzione domina, anche guadagni modesti ma persistenti meritano
investigazione: non c'è ragione di escludere C per proteggere l'investimento
in Julia. Non c'è però ancora una misura che attribuisca a C o Odin quel
vantaggio residuo.

La direzione proposta è rendere prima espliciti invarianti, dati caldi e
confini dei kernel, poi conservare le implementazioni native che vincono
il confronto reale. Le prime evidenze indicano lavoro evitabile anche in
Julia; C è il candidato scelto per verificare quanto margine ulteriore
offrano controllo del layout, SIMD e integrazione con la macchina.
