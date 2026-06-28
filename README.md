# FolderBase

File manager metadata-first per macOS.

FolderBase trasforma cartelle e file reali del Mac in viste tabellari arricchite da metadata custom, come note, stato, select, date, checkbox e altri campi configurabili.

## MVP

- Sidebar con cartelle preferite e dischi
- Vista tabellare dei file
- Colonne standard: Name, Type, Created, Size
- Colonne metadata: Nota, Stato
- Salvataggio metadata locale in SQLite
- Apertura file con app predefinita
- QuickLook in fase successiva

## Stack previsto

- Swift
- SwiftUI
- AppKit / NSTableView per la tabella avanzata
- SQLite / GRDB
- FileManager API
- QuickLook
- FSEvents
