# FolderBase

**File manager *metadata-first* per macOS.**

FolderBase mostra cartelle e file reali del tuo Mac in una tabella alla quale puoi aggiungere colonne personalizzate — note, numeri, date, stati Kanban, tag e link — senza mai spostare, copiare o modificare i file originali. I metadata vivono in un database SQLite locale separato e *seguono i file* anche quando li rinomini o li sposti.

L'idea è avvicinare l'esperienza di uno strumento tipo Notion/Airtable ai file veri del filesystem: il Finder mostra solo nome, dimensione e data; FolderBase ti lascia annotare, classificare e organizzare lo stesso contenuto con campi tuoi.

> 🇬🇧 A metadata-first file manager for macOS: enrich real files and folders with custom columns (notes, numbers, dates, Kanban, tags, links) without ever moving or altering them. UI available in Italian and English. MIT licensed — free to use, fork and build.

---

## Scaricare l'app (già compilata)

Vai nella sezione **[Releases](../../releases)** e scarica `FolderBase-x.y.dmg`. Apri il DMG e trascina **FolderBase** nella cartella **Applications**.

### ⚠️ Disclaimer — app non notarizzata

FolderBase è distribuita **firmata ad-hoc ma NON notarizzata da Apple**. Al primo avvio macOS (Gatekeeper) mostrerà un avviso del tipo *"Impossibile aprire FolderBase perché lo sviluppatore non può essere verificato"*. Questo è normale per un'app open source distribuita senza un account Apple Developer a pagamento e **non indica che l'app sia dannosa**.

Per aprirla la prima volta:

1. Nel **Finder**, vai in `Applications`, fai **clic destro** su `FolderBase.app` → **Apri**.
2. Nella finestra di avviso, conferma **Apri**.

In alternativa, da Terminale puoi rimuovere l'attributo di quarantena:

```bash
xattr -dr com.apple.quarantine /Applications/FolderBase.app
```

Da quel momento l'app si avvia normalmente. Se preferisci non fidarti del binario precompilato, puoi sempre **compilarla tu** dai sorgenti (vedi sotto): il risultato è identico.

---

## Compilare dai sorgenti

Requisiti: **macOS 14.4+** e **toolchain Swift 5.9+** (Xcode recente o i Command Line Tools).

```bash
git clone https://github.com/PaoloSturbini/FolderBase.git
cd FolderBase
swift run --build-path /tmp/folderbase-run FolderBase
```

La build viene messa in `/tmp/folderbase-run` (fuori dalla cartella del progetto) per tenerla pulita. Script di comodo:

```bash
./build.sh             # solo compilazione (debug)
./build.sh -c release  # build di release
./run.sh               # compila e avvia
./make-app.sh          # crea il bundle .app e lo installa in /Applications
./make-dmg.sh          # crea un .dmg distribuibile in dist/
```

In alternativa puoi aprire `Package.swift` con Xcode e premere ▶︎.

---

## Funzionalità principali

- Sidebar con cartelle recenti, albero della struttura e configurazione a sezioni.
- Tabella nativa con colonne standard (Nome, Tipo, Creato, Dimensioni) + colonne **metadata per-cartella**.
- Tipi di colonna: **nota libera, numero, data, Kanban, Select** (tag colorati) e **link** (URL, file locali, markdown e wiki link `[[…]]`).
- Vista **Kanban a board** con drag tra colonne.
- Ricerca, filtri a chip, ordinamento, selezione multipla e **modifica in blocco**, export **CSV**.
- I metadata seguono i file su **rename e spostamenti** (identità basata sugli identificatori filesystem di macOS).
- **Manutenzione** del DB: riallineamento e pulizia degli orfani.
- Tema chiaro / scuro / automatico, dimensione caratteri regolabile.
- **Interfaccia in Italiano e Inglese**, con guida d'uso integrata (Configurazione → Aiuto).
- Salvataggio locale e non invasivo in `~/Library/Application Support/FolderBase/folderbase.sqlite`: le tue cartelle non vengono mai modificate.

---

## Stack

Swift · SwiftUI · Swift Package Manager · SQLite (metadata e indice locale) · FileManager / AppKit.

Struttura del codice e dettagli architetturali nel **[MANUALE.md](MANUALE.md)**.

---

## Contribuire

Il progetto è open source con licenza MIT: sei libero di **usarlo, modificarlo, forkarlo e ridistribuirlo**. Issue e pull request sono benvenute.

## Licenza

Distribuito con licenza **MIT** — vedi il file [LICENSE](LICENSE). © 2026 Paolo Sturbini.
