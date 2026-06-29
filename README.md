# FolderBase

File manager metadata-first per macOS.

FolderBase trasforma cartelle e file reali del Mac in viste tabellari arricchite da metadata custom, come note, stato, select, date, checkbox e altri campi configurabili.

## MVP

- Sidebar con pulsante per scegliere una cartella
- Vista tabellare dei file
- Colonne standard: Name, Type, Created, Size
- Colonne metadata: Nota, Stato
- Nota modificabile
- Stato modificabile con valori Todo, Doing, Done
- Colonne metadata aggiuntive: nota libera, select con valori custom, link a file/cartelle o URL
- Salvataggio metadata locale in `~/Library/Application Support/FolderBase/metadata.json`

## Stack

- Swift
- SwiftUI
- Swift Package
- JSON per MVP
- FileManager API
