# FolderBase — Manuale

**FolderBase** è un file manager *metadata-first* per macOS. Mostra cartelle e file reali del tuo Mac in una tabella alla quale puoi aggiungere colonne personalizzate — note, numeri, date, stati Kanban, tag Select, link — senza mai spostare, copiare o modificare i file originali. I metadata vivono in un database locale separato e seguono i file anche quando li rinomini o li sposti.

Oltre all'organizzazione per metadata, FolderBase include un livello di **intelligenza artificiale opzionale**: può indicizzare il contenuto dei documenti (con OCR per PDF scansionati e immagini), abilitare una **ricerca ibrida per significato** e una **chat che risponde alle domande sui tuoi documenti citando le fonti**. Tutte le funzioni AI sono disattivabili con un unico interruttore: quando sono spente, FolderBase resta un file manager classico.

L'idea è avvicinare l'esperienza di uno strumento tipo Notion/Airtable ai file veri del filesystem: il Finder mostra solo nome, dimensione e data; FolderBase ti lascia annotare, classificare, cercare e interrogare lo stesso contenuto con campi e strumenti tuoi.

---

## 1. Requisiti

- **macOS 14.4 o superiore** — necessario per le colonne dinamiche del componente tabella nativo (`Table` + `TableColumnForEach`).
- **Toolchain Swift 5.9+** (Xcode recente oppure i Command Line Tools) — solo se compili dai sorgenti.
- **Facoltativo, per le funzioni AI avanzate:** un motore locale [Ollama](https://ollama.com) oppure una chiave API OpenAI. Il motore di embedding *su questo Mac* (Apple) è integrato, gratuito e privato, e non richiede nulla.

---

## 2. Installazione ed esecuzione

Hai tre modi per avviare FolderBase, dal più rapido al più "definitivo".

### 2.1 Avvio diretto da terminale

```bash
git clone https://github.com/PaoloSturbini/FolderBase.git
cd FolderBase
swift run --build-path /tmp/folderbase-run FolderBase
```

La build viene messa in `/tmp/folderbase-run`, **fuori** dalla cartella del progetto, così la directory resta pulita ed evita problemi di sincronizzazione.

### 2.2 Script di comodo

```bash
./build.sh            # solo compilazione (debug)
./build.sh -c release # build di release
./run.sh              # compila e avvia
```

### 2.3 Creare una vera app in /Applications

```bash
./make-app.sh   # crea il bundle FolderBase.app e lo installa in /Applications
./make-dmg.sh   # crea un .dmg distribuibile in dist/
```

`make-app.sh` compila in release e assembla un bundle `FolderBase.app` in `/Applications`, con `Info.plist` (bundle id `com.paolosturbini.folderbase`, min OS 14.4) e icona generata da `AppIcon.png` (idealmente 1024×1024) presente nella cartella del progetto. Applica anche una firma ad-hoc per ridurre gli avvisi all'avvio locale. Da qui in poi puoi lanciare FolderBase come una normale app dal Launchpad/Dock.

In alternativa puoi aprire `Package.swift` con Xcode e premere ▶︎.

---

## 3. Dove vengono salvati i dati

Tutti i metadata, l'indice dei file e — se attive le funzioni AI — testo estratto ed embedding stanno in un singolo database SQLite locale:

```
~/Library/Application Support/FolderBase/folderbase.sqlite
```

Punti importanti:

- Le **cartelle osservate non vengono mai modificate**: FolderBase non scrive file nascosti dentro le tue directory.
- Per ripartire "puliti" basta cancellare quel file: verrà ricreato vuoto al successivo avvio.
- Se esiste un vecchio `metadata.json` (formato legacy), viene importato **una sola volta** in SQLite quando il database è ancora vuoto, poi non è più usato.
- I contenuti indicizzati per l'AI e gli embedding restano **in locale** nello stesso database. Solo se scegli un motore *cloud* (OpenAI) alcuni testi vengono inviati al provider (vedi §6).

---

## 4. Guida all'uso

### 4.1 Aggiungere e aprire una cartella

1. Apri **Configurazione** nella sidebar, vai in **Cartelle** e usa **Aggiungi cartella**. La cartella entra nell'elenco delle recenti.
2. All'avvio l'app riapre automaticamente l'ultima cartella usata e mostra subito l'albero.

### 4.2 Navigare

- **Singolo click**: seleziona una riga.
- **Doppio click** (o **Invio**) sul nome di una sottocartella: ci entra, come nel Finder.
- In alto trovi i pulsanti **Indietro / Avanti / Su (↑)** e il percorso corrente.
- L'**albero a sinistra** parte dalla cartella selezionata: cliccando un nodo la tabella si aggiorna. Puoi **trascinare file dalla tabella (o dalla board) su una cartella dell'albero** per spostarli lì.

La tabella si **aggiorna da sola** quando aggiungi, rimuovi o rinomini file nella cartella corrente dall'esterno (Finder, terminale…), grazie al watcher basato su **FSEvents**.

### 4.3 Colonne standard

Ogni tabella mostra di base: **Name**, **Type**, **Created**, **Size**. Le cartelle non hanno dimensione (`—`).

### 4.4 Aggiungere colonne metadata

Pulsante **+ Colonna** in alto a destra. Le colonne create in una cartella vengono **ereditate da tutte le sue sottocartelle**. Se una sottocartella contiene già una colonna con lo stesso nome, prevale la definizione della cartella superiore. Tipi disponibili:

| Tipo | A cosa serve | Ordinamento |
|------|--------------|-------------|
| **Nota libera** | Campo di testo libero (anteprima al passaggio del mouse) | Alfabetico |
| **Numero** | Valore numerico (accetta sia `.` sia `,` come separatore) | Numerico reale |
| **Data** | Selettore data; salvata come `yyyy-MM-dd`, mostrata in formato localizzato | Cronologico |
| **Kanban** | Tag con stati **ToDo, Doing, Done** già pronti; abilita la vista a board | Per stato |
| **Select** | Tag a valori liberi con colore scelto; il vuoto appare come `<vuoto>` | Per valore |
| **Link** | URL, path locale, markdown link o wiki link `[[Nota]]`, con pulsanti per scegliere file/cartelle, collegare una nota e aprire | — |

I tag colorati (Select e Kanban) possono usare 8 colori: grigio, rosso, arancio, giallo, verde, blu, viola, rosa. Se rinomini un'opzione, i valori già assegnati in tabella vengono aggiornati; se la elimini, viene rimossa anche dalle righe che la usavano.

### 4.5 Template di colonne

Un **template** è un insieme di colonne (nome + tipo) riutilizzabile. Il pulsante con l'icona template in alto a sinistra è disponibile nella cartella radice selezionata e in ogni sua sottocartella, anche se esistono già colonne. Le colonne applicate vengono ereditate da tutto il sottoalbero. I template si creano e si modificano da **Configurazione → Template**.

### 4.6 Gestire le colonne

- **Ridimensiona / riordina**: trascina bordi e intestazioni.
- **Mostra / nascondi**: clic destro sull'intestazione.
- **Elimina**: dal menù **Colonne**.
- Larghezza, ordine e visibilità sono **persistenti ed ereditati** dalle sottocartelle; nei conflitti prevale la configurazione dell'antenato più alto della radice selezionata.

### 4.7 Ordinare

Clicca l'intestazione di una colonna per ordinare; ricliccala per invertire. I valori vuoti finiscono **sempre in fondo**. **Ordine predefinito** ripristina la disposizione base (cartelle prima, poi per nome).

### 4.8 Cercare e filtrare

La **barra di ricerca** in alto offre due modalità, selezionabili accanto al campo:

- **Nome** — filtra per nome file e per qualsiasi valore metadata. Con l'opzione *"Cerca anche nelle sottocartelle"* la ricerca si estende all'intero sottoalbero.
- **Contenuto (AI)** — ricerca **ibrida** che unisce parole esatte (full-text) e significato (semantica), disponibile solo se le funzioni AI sono attive e la cartella è stata indicizzata. Quando l'AI è disattivata, resta solo la ricerca per nome.

Il menù **Filtri** mostra solo gli elementi con certi valori Select/Kanban; i filtri attivi appaiono come **chip rimovibili**.

### 4.9 Selezione multipla e modifica in blocco

Seleziona più righe con **Cmd-click** / **Shift-click**. Compaiono:

- **Modifica** — imposta lo stesso valore metadata su tutta la selezione (in un'unica transazione).
- **Cestina** — sposta gli elementi nel Cestino.

### 4.10 Vista Kanban (board)

Se nella cartella esiste una colonna **Kanban**, l'interruttore **tabella / board** in alto mostra le card raggruppate per stato. **Trascina una card** in un'altra colonna per cambiarne lo stato.

### 4.11 Pannello dettagli (inspector)

Sotto l'albero, nella sidebar, un **pannello dettagli** mostra e permette di modificare i metadata dell'elemento selezionato senza dover scorrere la tabella. Se non c'è selezione, invita a selezionare un file.

### 4.12 Gestire file e cartelle

Clic destro su un elemento per: **Apri**, **Anteprima rapida** (Quick Look), **Mostra nel Finder**, **Rinomina**, **Sposta**, **Imposta metadata**, **Sposta nel Cestino**.

- Dalla **Configurazione → Cartelle** puoi creare file vuoti e cartelle nella directory corrente.
- **Esporta CSV** (icona condividi) salva la tabella corrente rispettando filtri e ordinamento attivi.

### 4.13 Modificare i metadata

Scrivi direttamente nelle celle: il salvataggio è **automatico**. Le note di testo vengono salvate con un breve ritardo (debounce ~0,4 s) per non scrivere su disco a ogni tasto.

---

## 5. Le funzioni di intelligenza artificiale

Le funzioni AI sono **opt-in**. In **Configurazione → Funzioni di A.I.** trovi un interruttore generale (**Intelligenza artificiale**): quando è spento, le icone della chat spariscono e la ricerca funziona solo per nome; quando è acceso, si sbloccano indicizzazione, ricerca per contenuto e chat.

### 5.1 Indicizzazione dei contenuti

L'indicizzazione estrae il testo dei file della cartella **e di tutte le sottocartelle** e ne calcola gli embedding. Supporta:

- Documenti di testo, PDF, Office (Word/PowerPoint/Excel, inclusi i formati legacy `.xls`/`.ppt`) e iWork (`.pages`/`.numbers`/`.key`, via anteprima QuickLook).
- **OCR** per PDF scansionati e immagini, così anche i documenti senza testo selezionabile diventano cercabili.
- **Reindicizzazione incrementale**: la fai una volta; ai successivi avvii vengono rielaborati solo i file cambiati. I file senza testo estraibile contano comunque come "coperti".

Lo stato dell'indicizzazione è memorizzato e mostrato in Configurazione, con una diagnostica che distingue un **motore non raggiungibile** da problemi sui **singoli file**.

### 5.2 Motore di embedding (intercambiabile)

Puoi scegliere come vengono calcolati gli embedding:

- **Su questo Mac (Apple)** — integrato, **gratuito e privato**, nessun dato esce dal Mac.
- **Locale (Ollama)** — qualità superiore; richiede Ollama in esecuzione (imposti URL e modello).
- **Cloud (OpenAI)** — massima qualità; richiede una chiave API (BYOK, salvata nel **Portachiavi** di macOS). In questo caso i testi vengono inviati a OpenAI.

> Se cambi motore, **reindicizza** le cartelle: i vettori di motori diversi non sono compatibili. Il pulsante **Prova** verifica al volo che il motore selezionato risponda.

### 5.3 Chat con i documenti (RAG)

La chat risponde alle domande sui tuoi documenti indicizzati basandosi sui contenuti trovati e **citando le fonti**. Caratteristiche:

- **Retrieval ibrido** (semantico + lessicale con fusione RRF) e comprensione della domanda, per fonti più pertinenti.
- **Ambito** selezionabile: tutto l'indice, la cartella corrente o un singolo file.
- **Selettore delle fonti** con disambiguazione di versioni/documenti simili (se un file sembra una versione precedente di un altro, la chat privilegia il più recente e segnala le differenze).
- **Cross-lingua**: il retrieval funziona su più spazi (lingue/motori diversi).
- Il **modello di chat** è a parte rispetto all'embedding: scegli Ollama (locale) oppure OpenAI (cloud). Su questo Mac non è integrato un modello di chat. Puoi regolare quante fonti recuperare per domanda e testare il modello con **Prova chat**.

---

## 6. Privacy delle funzioni AI

- Con il motore **Apple** (su questo Mac) e la chat **Ollama** (locale), **nessun dato esce dal tuo Mac**.
- Con **OpenAI** (embedding o chat), le domande e gli **estratti dei file** vengono inviati a OpenAI: usalo solo se sei d'accordo con questo. La chiave API è conservata nel Portachiavi, non nel database né in chiaro.
- L'interruttore generale spento equivale a non avere alcuna funzione AI attiva.

---

## 7. Impostazioni (Configurazione ⚙︎)

La Configurazione è organizzata in sezioni:

- **Cartelle** — cartelle monitorate e recenti, creazione file/cartelle.
- **Aspetto** — tema **automatico / chiaro / scuro**, dimensione dei caratteri e **colore d'accento** (barre di selezione ed evidenziazioni), con colori predefiniti o un colore personalizzato.
- **Visualizzazione** — opzioni della tabella: mostra file/cartelle **nascosti**, mostra **estensioni** nei nomi, **icona nella barra dei menu** (permette di chiudere/ridurre la finestra e riaprirla da lì su una delle cartelle).
- **Avvio** — **apertura automatica al login** del Mac (via `SMAppService`).
- **Lingua** — interfaccia in **Italiano / English** (cambio immediato).
- **Template** — insiemi di colonne riutilizzabili (§4.5).
- **Funzioni di A.I.** — interruttore generale, indicizzazione, motore embedding e chat (§5).
- **Manutenzione** — riallineamento dei metadata e pulizia degli **orfani**, con opzione di pulizia automatica.
- **Backup** — backup e ripristino del database (§8).
- **Aiuto** — apre la guida d'uso nel browser, nella lingua selezionata.
- **Info su FolderBase** — versione, controllo aggiornamenti su GitHub e link **Ko-fi** per sostenere lo sviluppo.

---

## 8. Backup e ripristino

FolderBase salva i metadata (colonne e valori) nel database SQLite. Da **Configurazione → Backup** puoi:

- Fare un **backup manuale** del database.
- Pianificare **backup automatici** in una cartella di destinazione, con intervallo e numero di copie da mantenere (oltre il limite, i più vecchi vengono eliminati). I file di backup hanno data e ora nel nome.
- **Ripristinare** uno stato precedente da un file di backup. Prima del ripristino, FolderBase salva automaticamente una copia di sicurezza del database corrente.

---

## 9. Come funziona l'identità dei file

Il cuore di FolderBase è il modo in cui lega i metadata ai file:

- Ogni file/cartella ha un'**identità stabile** calcolata dagli identificatori filesystem di macOS (`fileResourceIdentifier` + `volumeIdentifier`), con fallback al path solo se l'identificatore non è disponibile.
- I metadata sono legati a questa identità, **non al path**: il path è solo l'ultima posizione nota. Per questo le note "seguono" un file quando lo rinomini o lo sposti sullo stesso volume.
- Se un'operazione fatta dall'app genera una nuova identità, FolderBase **migra** metadata e colonne sulla nuova identità (`reconcileMovedItem`).
- Le definizioni delle colonne appartengono a una cartella, ma la configurazione effettiva è **gerarchica**: ogni sottocartella eredita le colonne degli antenati e la definizione superiore prevale sui nomi in conflitto.

---

## 10. Architettura del codice

```
FolderBase/
├── Package.swift            # target macOS 14.4, eseguibile "FolderBase", linka sqlite3
└── FolderBase/
    ├── App/        FolderBaseApp.swift        # entry point + finestra + icona menu bar
    ├── Models/     FileItem.swift             # file/cartella (identity, url, name, type, created, size)
    │               MetadataField.swift        # colonna metadata + tipi + tag colorati + formatter
    │               MetadataTemplate.swift      # template di colonne riutilizzabili
    ├── Services/   FileBrowserService.swift   # legge il contenuto di una cartella (puro, thread-safe)
    │               DirectorySnapshotCache.swift # cache LRU condivisa da tabella/albero e Back/Forward
    │               MetadataStore.swift        # metadata e colonne per-cartella (SQLite, cache identità, scritture debounced)
    │               FSEventsWatcher.swift      # auto-refresh basato su FSEvents (con difese anti-crash fd 0)
    │               FolderWatcher.swift        # watcher legacy su vnode (DispatchSource)
    │               RecentFoldersStore.swift   # cartelle recenti (UserDefaults)
    │               TemplateStore.swift        # persistenza dei template
    │               BackupService.swift        # backup manuali/automatici e ripristino del DB
    │               LaunchAtLoginService.swift # avvio al login (SMAppService)
    │               HelpService.swift          # apertura della guida nel browser
    │               UpdateService.swift        # controllo aggiornamenti su GitHub
    │               FileIconProvider.swift     # icone dei file
    │               Localization.swift         # stringhe IT/EN a runtime, funzione L()
    │               AI/
    │                 IndexingService.swift    # indicizzazione contenuti + stato + diagnostica
    │                 TextExtractor.swift      # estrazione testo/OCR (con runProcess a prova di hang)
    │                 EmbeddingProvider.swift  # astrazione motori di embedding
    │                 RemoteEmbedders.swift    # embedder Ollama / OpenAI
    │                 ChatProvider.swift       # astrazione modelli di chat
    │                 ChatService.swift        # chat RAG: retrieval ibrido, multi-turn, fonti
    │                 SourceSelector.swift     # selezione/disambiguazione delle fonti
    │                 AIProviderSettings.swift # impostazioni provider AI
    │                 KeychainStore.swift      # chiavi API nel Portachiavi
    └── UI/         MainWindowView.swift       # layout, navigazione, trash, spostamenti, ricerca
                    SidebarView.swift          # sidebar: cartelle, albero, inspector, Configurazione
                    DirectoryTreeView.swift    # albero directory espandibile (lazy, drop-to-move)
                    FileTableView.swift        # tabella nativa: colonne dinamiche, selezione, filtri, CSV
                    KanbanBoardView.swift      # vista a board con drag tra colonne
                    ChatView.swift             # interfaccia della chat con i documenti
                    MetadataFieldEditorView.swift # editor delle colonne metadata
                    TemplateEditorView.swift   # editor dei template
                    MenuBarMenu.swift          # menù dell'icona nella barra dei menu
                    QuickLookSheet.swift       # anteprima rapida (QLPreviewView)
```

### Database SQLite

Tabelle principali:

- **`files`** — `identity` (PK), identificatori filesystem, `last_known_path`, nome, flag directory, timestamp.
- **`metadata_fields`** — definizione delle colonne per cartella: `id`, `folder_identity`, nome, tipo, `options_json`, posizione (FK su `files`, `ON DELETE CASCADE`).
- **`metadata_values`** — i valori: `file_identity` + `field_id` (PK composta) → `value` (FK su `files` e `metadata_fields`, `ON DELETE CASCADE`).
- Tabelle di **indicizzazione AI** — testo estratto, indice full-text (FTS5) ed embedding vettoriali per la ricerca semantica e la chat.

Pragma attivi: `foreign_keys = ON`, `journal_mode = WAL`.

### Scelte di performance

- L'identità file è **in cache** per path e l'indice metadata è separato da filtro/sort, con norme dei vettori precalcolate: nessuna scrittura su disco durante il rendering di SwiftUI.
- Le note di testo si salvano con **debounce**; le modifiche in blocco usano una **singola transazione**.
- `FileBrowserService` è puro e senza stato, quindi le letture delle cartelle possono girare in background; il reconcile è asincrono.
- Tabella e albero condividono una **cache LRU di snapshot**: Back/Forward mostra subito il contenuto noto e lo aggiorna in background.
- FSEvents osserva solo le radici selezionate e invalida il ramo coinvolto, senza ricreare lo stream o ricaricare tutto l'albero a ogni navigazione.
- L'estrazione testo usa un `runProcess` con timeout e SIGKILL per evitare blocchi dell'indicizzazione.

---

## 11. FAQ e risoluzione problemi

**I miei metadata sono spariti dopo aver spostato un file.**
Dovrebbero seguirlo automaticamente sullo stesso volume. Se sposti tra volumi diversi (es. su un disco esterno) l'identità filesystem cambia e i metadata potrebbero non migrare.

**La ricerca per contenuto non trova nulla.**
Verifica che l'interruttore **Intelligenza artificiale** sia acceso e che tu abbia **indicizzato** la cartella (Configurazione → Funzioni di A.I.). Se hai cambiato motore di embedding, reindicizza.

**La chat dice che non c'è un modello configurato.**
La chat richiede un motore locale (Ollama) o cloud (OpenAI): impostalo in Configurazione → Funzioni di A.I. → *Chat con i documenti*. Su questo Mac non c'è un modello di chat integrato.

**Voglio azzerare tutto.**
Chiudi l'app e cancella `~/Library/Application Support/FolderBase/folderbase.sqlite`. Le tue cartelle e i tuoi file restano intatti. In alternativa usa **Backup → Ripristina** per tornare a uno stato precedente.

**La build "sporca" la cartella del progetto.**
Usa sempre `--build-path /tmp/folderbase-run` (o gli script forniti): la cartella `.build` è già in `.gitignore`.

**L'app non parte come bundle dopo `make-app.sh`.**
Manca `AppIcon.png` o la firma ad-hoc non è andata a buon fine: l'app userà l'icona generica ma dovrebbe comunque avviarsi. Per la distribuzione fuori dal tuo Mac servono notarizzazione e security-scoped bookmark.

---

## 12. Limiti noti e migliorie possibili

- **Robustezza identità**: l'identità si basa su `String(describing:)` dell'identificatore filesystem; si potrebbe ancorarla a `bookmark_data` per maggiore stabilità tra riavvii.
- **Volumi diversi**: lo spostamento tra volumi può generare una nuova identità e richiedere la migrazione manuale dei metadata.
- **Sandbox/distribuzione**: per distribuire l'app fuori da `swift run` servono security-scoped bookmark risolti all'avvio e la notarizzazione Apple.
- **Motori AI cloud**: usando OpenAI, testi ed estratti lasciano il Mac; per la massima privacy usa il motore Apple o Ollama in locale.

---

*Repository: https://github.com/PaoloSturbini/FolderBase*
