# FolderBase

File manager metadata-first per macOS.

FolderBase trasforma cartelle e file reali del Mac in viste tabellari arricchite da metadata custom, come note, stato, select, date, checkbox e altri campi configurabili.

## MVP

- Sidebar con cartelle recenti e configurazione a sezioni
- Vista tabellare dei file
- Colonne standard: Name, Type, Created, Size
- Colonne metadata: Nota, Stato
- Nota modificabile
- Stato modificabile con valori Todo, Doing, Done
- Colonne metadata aggiuntive: nota libera, kanban, select con tag colorati, link a file/cartelle o URL
- Salvataggio metadata locale in `~/Library/Application Support/FolderBase/folderbase.sqlite`
- Identificazione file tramite identificatori filesystem macOS, così i metadata seguono rename e spostamenti sullo stesso volume
- Creazione di file vuoti e cartelle nella directory corrente dalla configurazione in sidebar
- Ordinamento diretto dalle intestazioni delle colonne, incluse quelle metadata
- Rinomina e spostamento di file/cartelle con riallineamento del DB SQLite
- Tema chiaro, scuro o automatico dalle impostazioni Aspetto
- Link Ko-fi nella configurazione per sostenere lo sviluppo
- Campi link compatibili con URL, file locali, markdown link e wiki link

## Compilare ed eseguire

Requisiti: macOS 14.4+ e toolchain Swift 5.9+.

```bash
cd "/Users/paolosturbini/Documents/Sviluppo App/FolderBase"
swift run --build-path /tmp/folderbase-run FolderBase
```

La build viene messa in `/tmp/folderbase-run` (fuori dalla cartella del progetto) per tenerla pulita ed evitare problemi di sincronizzazione. In alternativa ci sono due script:

```bash
./build.sh            # solo compilazione
./build.sh -c release # build di release
./run.sh              # compila e avvia
```

## Stack

- Swift
- SwiftUI
- Swift Package
- SQLite per metadata e indice locale non invasivo
- FileManager API
