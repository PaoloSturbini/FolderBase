# FolderBase — Manuale

**FolderBase** è un file manager *metadata-first* per macOS. Mostra cartelle e file reali del tuo Mac in una tabella alla quale puoi aggiungere colonne personalizzate — note, numeri, date, stati Kanban, tag Select, link — senza mai spostare, copiare o modificare i file originali. I metadata vivono in un database locale separato e seguono i file anche quando li rinomini o li sposti.

L'idea è avvicinare l'esperienza di uno strumento tipo Notion/Airtable ai file veri del filesystem: il Finder mostra solo nome, dimensione e data; FolderBase ti lascia annotare, classificare e organizzare lo stesso contenuto con campi tuoi.

---

## 1. Requisiti

- **macOS 14.4 o superiore** — necessario per le colonne dinamiche del componente tabella nativo (`Table` + `TableColumnForEach`).
- **Toolchain Swift 5.9+** (Xcode recente oppure i Command Line Tools).

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
./make-app.sh
```

Lo script compila in release e assembla un bundle `FolderBase.app` in `/Applications`, con `Info.plist` (bundle id `com.paolosturbini.folderbase`, min OS 14.4) e icona generata da `AppIcon.png` (idealmente 1024×1024) presente nella cartella del progetto. Applica anche una firma ad-hoc per ridurre gli avvisi all'avvio locale. Da qui in poi puoi lanciare FolderBase come una normale app dal Launchpad/Dock.

In alternativa puoi aprire `Package.swift` con Xcode e premere ▶︎.

---

## 3. Dove vengono salvati i dati

Tutti i metadata e l'indice dei file stanno in un singolo database SQLite locale:

```
~/Library/Application Support/FolderBase/folderbase.sqlite
```

Punti importanti:

- Le **cartelle osservate non vengono mai modificate**: FolderBase non scrive file nascosti dentro le tue directory.
- Per ripartire "puliti" basta cancellare quel file: verrà ricreato vuoto al successivo avvio.
- Se esiste un vecchio `metadata.json` (formato legacy), viene importato **una sola volta** in SQLite quando il database è ancora vuoto, poi non è più usato.

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

La tabella si **aggiorna da sola** quando aggiungi, rimuovi o rinomini file nella cartella corrente dall'esterno (Finder, terminale…), grazie al `FolderWatcher`.

### 4.3 Colonne standard

Ogni tabella mostra di base: **Name**, **Type**, **Created**, **Size**. Le cartelle non hanno dimensione (`—`).

### 4.4 Aggiungere colonne metadata

Pulsante **+ Colonna** in alto a destra. Le colonne valgono **solo per la cartella in cui le crei**. Tipi disponibili:

| Tipo | A cosa serve | Ordinamento |
|------|--------------|-------------|
| **Nota libera** | Campo di testo libero (anteprima al passaggio del mouse) | Alfabetico |
| **Numero** | Valore numerico (accetta sia `.` sia `,` come separatore) | Numerico reale |
| **Data** | Selettore data; salvata come `yyyy-MM-dd`, mostrata in formato localizzato | Cronologico |
| **Kanban** | Tag con stati **ToDo, Doing, Done** già pronti; abilita la vista a board | Per stato |
| **Select** | Tag a valori liberi con colore scelto; il vuoto appare come `<vuoto>` | Per valore |
| **Link** | URL, path locale, markdown link o wiki link `[[Nota]]`, con pulsanti per scegliere file/cartelle, collegare una nota e aprire | — |

I tag colorati (Select e Kanban) possono usare 8 colori: grigio, rosso, arancio, giallo, verde, blu, viola, rosa. Se rinomini un'opzione, i valori già assegnati in tabella vengono aggiornati; se la elimini, viene rimossa anche dalle righe che la usavano.

### 4.5 Gestire le colonne

- **Ridimensiona / riordina**: trascina bordi e intestazioni.
- **Mostra / nascondi**: clic destro sull'intestazione.
- **Elimina**: dal menù **Colonne**.
- Larghezza, ordine e visibilità sono **persistenti** (salvati via `TableColumnCustomization` in `@AppStorage`).

### 4.6 Ordinare

Clicca l'intestazione di una colonna per ordinare; ricliccala per invertire. I valori vuoti finiscono **sempre in fondo**. **Ordine predefinito** ripristina la disposizione base (cartelle prima, poi per nome).

### 4.7 Cercare e filtrare

- La **barra di ricerca** in alto filtra per nome e per qualsiasi valore metadata.
- Il menù **Filtri** mostra solo gli elementi con certi valori Select/Kanban.
- I filtri attivi appaiono come **chip rimovibili**.

### 4.8 Selezione multipla e modifica in blocco

Seleziona più righe con **Cmd-click** / **Shift-click**. Compaiono:

- **Modifica** — imposta lo stesso valore metadata su tutta la selezione (in un'unica transazione).
- **Cestina** — sposta gli elementi nel Cestino.

### 4.9 Vista Kanban (board)

Se nella cartella esiste una colonna **Kanban**, l'interruttore **tabella / board** in alto mostra le card raggruppate per stato. **Trascina una card** in un'altra colonna per cambiarne lo stato.

### 4.10 Gestire file e cartelle

Clic destro su un elemento per: **Apri**, **Anteprima rapida** (Quick Look), **Mostra nel Finder**, **Rinomina**, **Sposta**, **Imposta metadata**, **Sposta nel Cestino**.

- Dalla **Configurazione** puoi creare file vuoti e cartelle nella directory corrente.
- **Esporta CSV** (icona condividi) salva la tabella corrente rispettando filtri e ordinamento attivi.

### 4.11 Modificare i metadata

Scrivi direttamente nelle celle: il salvataggio è **automatico**. Le note di testo vengono salvate con un breve ritardo (debounce ~0,4 s) per non scrivere su disco a ogni tasto.

### 4.12 Impostazioni (Configurazione ⚙︎)

- **Cartelle** — gestione cartelle recenti, creazione file/cartelle.
- **Aspetto** — tema **automatico / chiaro / scuro** e scelta dei caratteri.
- **Sostieni** — link Ko-fi per supportare lo sviluppo.

---

## 5. Come funziona l'identità dei file

Il cuore di FolderBase è il modo in cui lega i metadata ai file:

- Ogni file/cartella ha un'**identità stabile** calcolata dagli identificatori filesystem di macOS (`fileResourceIdentifier` + `volumeIdentifier`), con fallback al path solo se l'identificatore non è disponibile.
- I metadata sono legati a questa identità, **non al path**: il path è solo l'ultima posizione nota. Per questo le note "seguono" un file quando lo rinomini o lo sposti sullo stesso volume.
- Se un'operazione fatta dall'app genera una nuova identità, FolderBase **migra** metadata e colonne sulla nuova identità (`reconcileMovedItem`).
- Le colonne metadata sono **per-cartella**: la chiave è l'identità filesystem della cartella.

---

## 6. Architettura del codice

```
FolderBase/
├── Package.swift            # target macOS 14.4, eseguibile "FolderBase", linka sqlite3
└── FolderBase/
    ├── App/        FolderBaseApp.swift      # entry point + finestra
    ├── Models/     FileItem.swift           # file/cartella (identity, url, name, type, created, size)
    │               MetadataField.swift      # colonna metadata + tipi + tag colorati + formatter
    ├── Services/   FileBrowserService.swift # legge il contenuto di una cartella (puro, thread-safe)
    │               MetadataStore.swift      # metadata e colonne per-cartella (SQLite, cache identità, scritture debounced)
    │               FolderWatcher.swift      # auto-refresh con debounce (DispatchSource sul vnode)
    │               RecentFoldersStore.swift # cartelle recenti (UserDefaults)
    └── UI/         MainWindowView.swift     # layout, navigazione, trash, spostamenti
                    SidebarView.swift        # sidebar: cartelle, albero, impostazioni
                    DirectoryTreeView.swift  # albero directory espandibile (lazy, drop-to-move)
                    FileTableView.swift      # tabella nativa: colonne dinamiche, selezione, filtri, CSV
                    KanbanBoardView.swift    # vista a board con drag tra colonne
                    QuickLookSheet.swift     # anteprima rapida (QLPreviewView)
```

### Database SQLite

Tre tabelle:

- **`files`** — `identity` (PK), identificatori filesystem, `last_known_path`, nome, flag directory, timestamp.
- **`metadata_fields`** — definizione delle colonne per cartella: `id`, `folder_identity`, nome, tipo, `options_json`, posizione (FK su `files`, `ON DELETE CASCADE`).
- **`metadata_values`** — i valori: `file_identity` + `field_id` (PK composta) → `value` (FK su `files` e `metadata_fields`, `ON DELETE CASCADE`).

Pragma attivi: `foreign_keys = ON`, `journal_mode = WAL`.

### Scelte di performance

- L'identità file è **in cache** per path: nessuna scrittura su disco durante il rendering di SwiftUI.
- Le note di testo si salvano con **debounce**; le modifiche in blocco usano una **singola transazione**.
- `FileBrowserService` è puro e senza stato, quindi le letture delle cartelle possono girare in background.

---

## 7. FAQ e risoluzione problemi

**I miei metadata sono spariti dopo aver spostato un file.**
Dovrebbero seguirlo automaticamente sullo stesso volume. Se sposti tra volumi diversi (es. su un disco esterno) l'identità filesystem cambia e i metadata potrebbero non migrare.

**Voglio azzerare tutto.**
Chiudi l'app e cancella `~/Library/Application Support/FolderBase/folderbase.sqlite`. Le tue cartelle e i tuoi file restano intatti.

**La build "sporca" la cartella del progetto.**
Usa sempre `--build-path /tmp/folderbase-run` (o gli script forniti): la cartella `.build` è già in `.gitignore`.

**L'app non parte come bundle dopo `make-app.sh`.**
Manca `AppIcon.png` o la firma ad-hoc non è andata a buon fine: l'app userà l'icona generica ma dovrebbe comunque avviarsi. Per la distribuzione fuori dal tuo Mac servono notarizzazione e security-scoped bookmark.

---

## 8. Limiti noti e migliorie possibili

- **Robustezza identità**: l'identità si basa su `String(describing:)` dell'identificatore filesystem; si potrebbe ancorarla a `bookmark_data` per maggiore stabilità tra riavvii.
- **Sandbox/distribuzione**: per distribuire l'app fuori da `swift run` servono security-scoped bookmark risolti all'avvio e una revisione del widget Ko-fi (usa una `WKWebView` con JS remoto).
- **Volumi diversi**: lo spostamento tra volumi può generare una nuova identità e richiedere la migrazione manuale dei metadata.

---

*Repository: https://github.com/PaoloSturbini/FolderBase*
