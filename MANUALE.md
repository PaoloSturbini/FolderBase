# FolderBase — Manuale iniziale

FolderBase è un file manager *metadata-first* per macOS. Prende cartelle e file reali del tuo Mac e li mostra in una tabella alla quale puoi aggiungere colonne personalizzate (note, stati, link…). I file non vengono spostati né duplicati: i metadata sono salvati a parte.

## Requisiti

- **macOS 14.4 o superiore** (necessario per le colonne dinamiche della tabella nativa).
- Toolchain Swift / Xcode recente (Swift 5.9+).

## Come compilare ed eseguire

Da terminale, nella cartella del progetto:

```bash
cd "/Users/paolosturbini/Documents/Sviluppo App/FolderBase"
swift build        # compila
swift run          # compila ed avvia l'app
```

In alternativa puoi aprire `Package.swift` con Xcode (`File → Open`) e premere ▶︎ (Run).

I metadata vengono salvati in:

```
~/Library/Application Support/FolderBase/metadata.json
```

Per ripartire "puliti" basta cancellare quel file (verrà ricreato).

## Come si usa

1. **Scegli una cartella** — pulsante in alto a sinistra nella sidebar. La cartella viene aggiunta all'elenco di quelle recenti.
2. **Naviga** — doppio uso: clicca il nome di una sottocartella nella tabella per entrarci, oppure usa l'albero nella sidebar. In alto trovi i pulsanti Indietro / Avanti / Su e il percorso corrente.
3. **Albero a sinistra** — mostra la struttura a partire dalla cartella selezionata; cliccando un nodo la tabella si aggiorna. Per risalire ai livelli superiori usa il pulsante **Su** (↑).
4. **Aggiungi colonne metadata** — pulsante **+ Colonna** in alto a destra. Puoi scegliere il tipo:
   - **Nota libera** — campo di testo.
   - **Select** — menù a tendina con i valori che definisci tu (uno per riga).
   - **Link** — percorso a un file/cartella o un URL, con pulsanti per scegliere e aprire.
   Le colonne valgono **solo per la cartella in cui le crei**.
5. **Ridimensiona, riordina e nascondi le colonne** — trascina i bordi delle intestazioni per ridimensionarle, trascina l'intestazione per riordinarle, e usa il menù contestuale (clic destro sull'intestazione) per mostrare/nascondere colonne. Larghezza, ordine e visibilità vengono **memorizzati tra una sessione e l'altra**.
6. **Ordina** — menù *Ordina* (in alto a destra): scegli la colonna; riselezionandola inverti la direzione. "Ordine predefinito" ripristina (cartelle prima, poi per nome).
7. **Elimina colonne** — menù *Colonne* (icona cursori): elenca le colonne metadata della cartella corrente con l'opzione di eliminarle.
8. **Modifica i metadata** — scrivi direttamente nelle celle; il salvataggio è automatico.
9. **Impostazioni** — pulsante *Configurazione* (ingranaggio) in basso nella sidebar: slider per la dimensione dei caratteri della sidebar e della tabella, con tasto di ripristino.

All'avvio l'app riapre automaticamente l'ultima cartella usata e mostra subito l'albero. La tabella si **aggiorna da sola** quando aggiungi/rimuovi/rinomini file nella cartella corrente dall'esterno (Finder, terminale…).

## Architettura del codice

```
FolderBase/
├── Package.swift            # target macOS 14.4, eseguibile "FolderBase"
└── FolderBase/
    ├── App/        FolderBaseApp.swift      # entry point + finestra
    ├── Models/     FileItem.swift           # file/cartella
    │               MetadataField.swift      # colonna metadata (text/select/link)
    ├── Services/   FileBrowserService.swift # legge il contenuto di una cartella
    │               MetadataStore.swift      # carica/salva metadata e colonne per-cartella (JSON)
    │               RecentFoldersStore.swift # cartelle recenti (UserDefaults)
    └── UI/         MainWindowView.swift     # layout, navigazione, stato
                    SidebarView.swift        # sidebar: cartelle, albero, impostazioni
                    DirectoryTreeView.swift  # albero directory espandibile (lazy)
                    FileTableView.swift      # tabella nativa con colonne dinamiche
```

Punti chiave:
- Le colonne metadata sono **per-cartella** (`MetadataStore.fieldsByFolder`, chiave = path).
- La tabella usa il componente nativo `Table` con un'unica `TableColumnForEach` su una lista unificata di colonne.
- L'albero ha la radice agganciata alla cartella selezionata.

## Funzionalità implementate di recente

- **Eliminazione colonne** dal menù *Colonne*.
- **Larghezze, ordine e visibilità colonne persistenti** (via `TableColumnCustomization`, salvati in `@AppStorage`).
- **Ordinamento** per qualsiasi colonna (menù *Ordina*, ascendente/discendente).
- **Auto-refresh** della cartella tramite `FolderWatcher` (DispatchSource sul vnode della directory).

## Cosa manca / migliorie possibili

- **Ordinamento cliccando direttamente l'intestazione**: ora l'ordinamento è dal menù *Ordina*. Il sort nativo via header-click con colonne dinamiche richiederebbe comparatori personalizzati ed è stato evitato per semplicità/robustezza.
- **Verifica del click sul nome**: nel `Table` nativo la riga gestisce anche la selezione; controllare che il singolo click apra/navighi correttamente. Se dà fastidio, si può passare al doppio-click.
- I metadata restano legati al **percorso**: spostando/rinominando un file dall'esterno i suoi metadata non lo seguono (servirebbe un identificatore stabile del file).
- Valutare in futuro un backend **SQLite** al posto del JSON se i volumi crescono (uno schema era già stato abbozzato e poi accantonato).

## Note

- Tutte le modifiche recenti **non sono ancora committate** su git (esiste solo il commit iniziale). Conviene fare un commit quando la build è verde.
- Il salvataggio metadata è legato al **percorso** del file: se sposti o rinomini un file fuori dall'app, i suoi metadata non lo seguono.
