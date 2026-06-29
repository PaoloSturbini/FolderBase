# FolderBase — Manuale iniziale

FolderBase è un file manager *metadata-first* per macOS. Prende cartelle e file reali del tuo Mac e li mostra in una tabella alla quale puoi aggiungere colonne personalizzate (note, stati, link…). I file non vengono spostati né duplicati: i metadata sono salvati a parte.

## Requisiti

- **macOS 14.4 o superiore** (necessario per le colonne dinamiche della tabella nativa).
- Toolchain Swift / Xcode recente (Swift 5.9+).

## Come compilare ed eseguire

Da terminale, nella cartella del progetto:

```bash
cd "/Users/paolosturbini/Documents/Sviluppo App/FolderBase"
swift run --build-path /tmp/folderbase-run FolderBase   # compila ed avvia
```

La build finisce in `/tmp/folderbase-run` (fuori dal progetto), così la cartella resta pulita. Scorciatoie: `./build.sh` (solo compila), `./run.sh` (compila e avvia). In alternativa apri `Package.swift` con Xcode e premi ▶︎.

I metadata vengono salvati in un database locale non invasivo:

```
~/Library/Application Support/FolderBase/folderbase.sqlite
```

Per ripartire "puliti" basta cancellare quel file (verrà ricreato). Le cartelle osservate non vengono modificate.

## Come si usa

1. **Aggiungi una cartella** — apri *Configurazione* nella sidebar, entra in *Cartelle* e usa **Aggiungi cartella**. La cartella viene aggiunta all'elenco di quelle recenti.
2. **Naviga** — **doppio click** (o Invio) sul nome di una sottocartella per entrarci, oppure usa l'albero nella sidebar. Il singolo click seleziona la riga. In alto trovi i pulsanti Indietro / Avanti / Su e il percorso corrente.
3. **Albero a sinistra** — mostra la struttura a partire dalla cartella selezionata; cliccando un nodo la tabella si aggiorna. Puoi **trascinare file dalla tabella (o dalla board) su una cartella dell'albero** per spostarli lì. Per risalire usa il pulsante **Su** (↑).
4. **Aggiungi colonne metadata** — pulsante **+ Colonna** in alto a destra. Tipi disponibili:
   - **Nota libera** — campo di testo (anteprima al passaggio del mouse).
   - **Numero** — valore numerico, ordinamento numerico reale.
   - **Data** — selettore data; ordinamento cronologico.
   - **Kanban** — tag con stati ToDo, Doing e Done già pronti; abilita la vista a board.
   - **Select** — tag con valori liberi e colore. Il valore vuoto appare come `<vuoto>`.
   - **Link** — URL, path locale, markdown link o wiki link `[[Nota]]`, con pulsanti per scegliere file/cartelle, collegare una nota e aprire.
   Le colonne valgono **solo per la cartella in cui le crei**.
5. **Ridimensiona, riordina e nascondi le colonne** — trascina i bordi/intestazioni; clic destro sull'intestazione per mostrare/nascondere. Larghezza, ordine e visibilità sono **persistenti**.
6. **Ordina** — clicca l'intestazione; riclicca per invertire. I valori vuoti finiscono sempre in fondo. "Ordine predefinito" ripristina (cartelle prima, poi per nome).
7. **Cerca e filtra** — la barra di ricerca in alto filtra per nome e per qualsiasi valore metadata; il menù **Filtri** permette di mostrare solo elementi con certi valori Select/Kanban. I filtri attivi appaiono come chip rimovibili.
8. **Selezione multipla e modifica in blocco** — seleziona più righe (Cmd/Shift-click); compaiono i pulsanti **Modifica** (imposta uno stesso valore metadata su tutta la selezione) e **Cestina**.
9. **Vista Kanban (board)** — se esiste una colonna Kanban, l'interruttore tabella/board in alto mostra le card raggruppate per stato; **trascina una card** in un'altra colonna per cambiarne lo stato.
10. **Gestisci file e cartelle** — clic destro su un elemento: Apri, **Anteprima rapida** (Quick Look), **Mostra nel Finder**, Rinomina, Sposta, Imposta metadata, **Sposta nel Cestino**. Dalla configurazione puoi creare file vuoti/cartelle. **Esporta CSV** (icona condividi) salva la tabella corrente (rispetta filtri e ordinamento).
11. **Modifica i metadata** — scrivi direttamente nelle celle; il salvataggio è automatico (le note di testo vengono salvate con un breve ritardo per non scrivere ad ogni tasto).
12. **Impostazioni** — *Configurazione* (ingranaggio): sezioni Cartelle, Aspetto (tema + caratteri), Sostieni.

All'avvio l'app riapre automaticamente l'ultima cartella usata e mostra subito l'albero. La tabella si **aggiorna da sola** quando aggiungi/rimuovi/rinomini file nella cartella corrente dall'esterno (Finder, terminale…).

## Architettura del codice

```
FolderBase/
├── Package.swift            # target macOS 14.4, eseguibile "FolderBase"
└── FolderBase/
    ├── App/        FolderBaseApp.swift      # entry point + finestra
    ├── Models/     FileItem.swift           # file/cartella
    │               MetadataField.swift      # colonna metadata (text/number/date/kanban/select/link) + formatter
    ├── Services/   FileBrowserService.swift # legge il contenuto di una cartella
    │               MetadataStore.swift      # metadata e colonne per-cartella (SQLite, cache identità, scritture debounced)
    │               FolderWatcher.swift      # auto-refresh con debounce
    │               RecentFoldersStore.swift # cartelle recenti (UserDefaults)
    └── UI/         MainWindowView.swift     # layout, navigazione, trash, spostamenti
                    SidebarView.swift        # sidebar: cartelle, albero, impostazioni
                    DirectoryTreeView.swift  # albero directory espandibile (lazy, drop-to-move)
                    FileTableView.swift      # tabella nativa: colonne dinamiche, selezione, filtri, CSV
                    KanbanBoardView.swift    # vista a board con drag tra colonne
                    QuickLookSheet.swift     # anteprima rapida (QLPreviewView)
```

Punti chiave:
- Le colonne metadata sono **per-cartella** (`MetadataStore.fieldsByFolder`, chiave = identità filesystem della cartella).
- I valori metadata sono legati all'identità filesystem del file, non al path; il path è solo l'ultima posizione nota.
- La tabella usa il componente nativo `Table` con un'unica `TableColumnForEach` su una lista unificata di colonne.
- L'albero ha la radice agganciata alla cartella selezionata.

## Funzionalità implementate di recente

- **Tipi colonna Numero e Data** con ordinamento numerico/cronologico.
- **Ricerca e filtri** per nome e valori metadata, con chip rimovibili.
- **Selezione multipla** con modifica metadata in blocco e cestino.
- **Vista Kanban a board** con drag tra colonne per cambiare stato.
- **Anteprima rapida (Quick Look)** e **Mostra nel Finder** dal menu contestuale.
- **Sposta nel Cestino** e **drag&drop di file su cartelle dell'albero**.
- **Esporta CSV** della tabella corrente (rispetta filtri e ordinamento).
- **Performance**: l'identità file è in cache (niente scritture su disco durante il render) e le note di testo vengono salvate con debounce; le modifiche in blocco usano una singola transazione.
- **Eliminazione colonne** dal menù *Colonne*.
- **Larghezze, ordine e visibilità colonne persistenti** (via `TableColumnCustomization`, salvati in `@AppStorage`).
- **Ordinamento diretto sulle intestazioni** per qualsiasi colonna, incluse quelle metadata.
- **Auto-refresh** della cartella tramite `FolderWatcher` (DispatchSource sul vnode della directory).
- **SQLite locale** in Application Support per metadata e indice file, senza scrivere file nascosti nelle directory utente.
- **Identità stabile file/cartelle** tramite identificatori filesystem macOS, con fallback al path solo se l'identificatore non è disponibile.
- **Creazione file vuoti/cartelle** dalla configurazione in sidebar, dentro la directory corrente.
- **Kanban e Select con tag colorati**: Kanban propone ToDo, Doing e Done; Select parte vuota. I valori selezionati vengono mostrati come pill colorate; se svuoti il nome di uno stato e salvi, quello stato viene eliminato anche dai valori già assegnati in tabella.
- **Rinomina e spostamento file/cartelle** dal menu contestuale della tabella, con aggiornamento del DB SQLite e migrazione metadata se cambia identità.
- **Tema app** automatico, chiaro o scuro nella sezione Aspetto.
- **Donazione Ko-fi** dalla sezione Sostieni.

## Cosa manca / migliorie possibili

- **Navigazione**: ora il singolo click seleziona e il doppio click (o Invio) apre/naviga, come nel Finder.
- Gli identificatori filesystem seguono rename e spostamenti sullo stesso volume. Se un'operazione fatta dall'app genera una nuova identità, FolderBase migra metadata e colonne sulla nuova identità.
- Il vecchio `metadata.json`, se presente, viene usato solo per una migrazione iniziale verso SQLite quando il DB è ancora vuoto.
- **Robustezza identità**: l'identità si basa su `String(describing:)` dell'identificatore filesystem; valutare di ancorarla al `bookmark_data` già salvato per maggiore stabilità tra riavvii.
- **Sandbox/distribuzione**: per distribuire l'app fuori da `swift run` servono security-scoped bookmark risolti all'avvio e una revisione del widget Ko-fi (usa una WKWebView con JS remoto).

## Note

- Tutte le modifiche recenti **non sono ancora committate** su git (esiste solo il commit iniziale). Conviene fare un commit quando la build è verde.
- Il salvataggio metadata è legato all'identità filesystem del file/cartella quando disponibile; le directory utente restano pulite.
