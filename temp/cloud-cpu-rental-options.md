# Valutazione e Opzioni per il Noleggio di CPU ad Alte Prestazioni (Cloud & Bare Metal)

Documento di sintesi sulle opzioni per il calcolo intensivo CPU (simulazione headless, generazione livelli e sweep in Julia) al minor costo possibile, evitando colli di bottiglia o costi nascosti.

---

## 1. Analisi del Workload e Fabbisogno Reale

* **Tipo di calcolo**: Simulazione pura multithread in Julia (CPU-bound, no GPU).
* **Consumo di Banda (Network Bandwidth)**:
  * **Setup iniziale**: Clone repository Git + runtime Julia + dipendenze Pkg (`~500 MB - 1 GB` una tantum).
  * **Output calcoli**: File di livelli generati, report/benchmark JSON, log o SVG (`pochi MB fino a decine di MB`).
  * **Conclusione Banda**: Anche sui provider dove il traffico in uscita si paga a consumo ($0.01 – $0.02 al GB), l'impatto economico totale per una run da 24-72h è nell'ordine di **pochi centesimi di dollaro**. La bandwidth **non** rappresenta una voce di costo significativa per questo workload.

---

## 2. Analisi di Vast.ai (Perché non è l'opzione ideale)

Sebbene su Vast.ai sia possibile trovare macchine con EPYC o Xeon ricche di core abbinate a GPU economiche (es. RTX 3090 a $0.20–$0.80/h), ci sono criticità specifiche per un carico CPU puro:

1. **Allocazione parziale dei Core (cgroups/taskset)**:
   * Le macchine con EPYC a 64 o 128 core montano solitamente da 4 a 8 GPU.
   * Se si noleggia una sola GPU, l'istanza Docker riceve di norma solo una quota proporzionale dei core (es. 1/4 o 1/8 dei 128 core, ovvero 16-32 vCPU).
   * Se i core non sono limitati rigidamente dall'host, essi sono comunque contesi con altri tenant che eseguono carichi pesanti di deep learning (saturazione della cache L3 e del bus di memoria).
2. **Affidabilità degli Host ("Community Cloud")**:
   * Gran parte delle macchine appartiene a privati o piccoli miner (PC in ambienti domestici o non condizionati).
   * Per job a lungo termine (24+ ore), esiste il rischio concreto di instabilità termica (thermal throttling), caduta della connessione o riavvii imprevisti.
   * Le istanze *Interruptible* possono essere terminate arbitrariamente se un altro utente fa un'offerta superiore.

---

## 3. Alternative CPU-Only Dedicate ed Economiche

### Opzione A: Hetzner Cloud (Fatturazione a ore/minuti — Consigliata per test e run brevi)

Datacenter professionali europei (Germania/Finlandia), fatturazione al minuto, 20 TB di traffico mensile inclusi gratuitamente, root SSH diretto.

* **Linea CCX (AMD EPYC, vCPU 100% dedicate, nessun vicino rumoroso)**:
  * **CCX33 (8 vCPU dedicate, 32 GB RAM)**: ~0,08 € / ora (~2 € / giorno)
  * **CCX43 (16 vCPU dedicate, 64 GB RAM)**: ~0,16 € / ora (~3,84 € / giorno)
  * **CCX53 (32 vCPU dedicate, 128 GB RAM)**: ~0,32 € / ora (~7,68 € / giorno)
  * **CCX63 (48 vCPU dedicate, 192 GB RAM)**: ~0,48 € / ora (~11,52 € / giorno)
* **Linea CAX (ARM64 Ampere Altra — Rapporto prezzo/prestazioni imbattibile)**:
  * Julia dispone di binari ufficiali compilati nativamente per Linux `aarch64`.
  * Ampere Altra non usa HyperThreading: ogni vCPU corrisponde a 1 core fisico reale dedicato.
  * **CAX41 (16 vCPU, 32 GB RAM)**: **~0,046 € / ora** (~1,10 € al giorno).

### Opzione B: AWS EC2 Spot Instances (Per scalare su decine di core on-demand)

Sfrutta la capacità computazionale in eccesso di AWS con sconti tra il 70% e l'80% rispetto al prezzo On-Demand.

* **Istanze `c6a` (AMD EPYC Milan)**:
  * `c6a.8xlarge` (32 vCPU, 64 GB RAM): tipicamente **~$0.35 – $0.45 / ora**.
  * `c6a.16xlarge` (64 vCPU, 128 GB RAM): tipicamente **~$0.70 – $0.85 / ora**.
* **Vantaggi**: Infrastruttura hyperscaler di prim'ordine, avvio immediato, terminazione istantanea quando il calcolo è completato.

### Opzione C: Hetzner Serverbörse / Server Auction (Bare Metal — Ideale per calcoli continui di settimane/mesi)

Se la generazione livelli deve girare continuativamente per 2–4 settimane, il noleggio orario diventa meno conveniente rispetto a un server bare-metal all'asta.

* **Hardware tipico**: AMD Ryzen 9 5950X / 3900X (16 core / 32 thread), 64–128 GB RAM, NVMe SSD.
* **Costo**: ~**35 € – 45 € / mese flat** (senza costi di setup, cancellabile mese per mese).
* **Vantaggio architetturale (Clock Speed vs Server Core count)**:
  * Gli EPYC server girano a frequenze base relativamente basse (2.2 – 2.8 GHz) per contenere i consumi nei rack.
  * I processori Ryzen spingono le frequenze su singoli e multi-core fino a 4.5 – 4.9 GHz.
  * Nei carichi di simulazione e generazione livelli in Julia, 16 core Ryzen ad alto clock possono pareggiare o superare l'output di 32–48 core EPYC lenti.

---

## 4. Guida Operativa Consigliata

1. **Setup rapido di prova**:
   * Creare un account su [Hetzner Cloud](https://www.hetzner.com/cloud).
   * Creare una chiave SSH e avviare una macchina **CCX43** (16 vCPU AMD) o **CCX53** (32 vCPU AMD) con Ubuntu/Debian.
2. **Esecuzione headless**:
   * Connettersi via SSH:
     ```bash
     ssh root@<IP_ISTANZA>
     ```
   * Installare Julia e clonare la codebase:
     ```bash
     # Installazione rapida Julia (o via jill / official tarball)
     curl -fsSL https://install.julialang.org | sh -s -- -y
     source ~/.bashrc
     git clone <URL_REPO> pevo && cd pevo/julia_clone
     julia --project=julia/PeggleSim -e 'using Pkg; Pkg.instantiate()'
     ```
   * Lanciare il calcolo in background persistente (es. con `tmux` o `nohup`):
     ```bash
     tmux new -s level_gen
     julia -t auto --project=julia/PeggleSim scripts/your_generator.jl
     # Staccarsi dal terminale premendo Ctrl+B poi D
     ```
3. **Raccolta dati e distruzione**:
   * Scaricare i risultati in locale tramite `rsync` o `scp`:
     ```bash
     rsync -avz root@<IP_ISTANZA>:/root/pevo/julia_clone/results/ ./results_cloud/
     ```
   * Eliminare l'istanza dal pannello web Hetzner Cloud per azzerare ogni costo futuro.
