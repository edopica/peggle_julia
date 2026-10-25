# Ottimizzazione del simulatore: memoria, parallelismo e costo

Sintesi della discussione del 24 ottobre 2026.

Questo documento raccoglie obiettivi, spiegazioni e ipotesi di ottimizzazione.
Non costituisce un benchmark, una decisione architetturale definitiva o una ricerca sulle offerte commerciali.

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
