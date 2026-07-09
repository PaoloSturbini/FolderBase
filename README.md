# FolderBase

**File manager *metadata-first* per macOS, con funzioni AI opzionali.**

FolderBase mostra cartelle e file reali del tuo Mac in una tabella alla quale puoi aggiungere colonne personalizzate — note, numeri, date, stati Kanban, tag e link — senza mai spostare, copiare o modificare i file originali. I metadata vivono in un database SQLite locale separato e *seguono i file* anche quando li rinomini o li sposti.

In più, con un livello di **intelligenza artificiale opzionale**, FolderBase può indicizzare il contenuto dei documenti (con OCR), abilitare una **ricerca ibrida per significato** e una **chat che risponde sui tuoi documenti citando le fonti**. Tutte le funzioni AI si disattivano con un unico interruttore: da spente, FolderBase resta un file manager classico.

L'idea è avvicinare l'esperienza di uno strumento tipo Notion/Airtable ai file veri del filesystem: il Finder mostra solo nome, dimensione e data; FolderBase ti lascia annotare, classificare, cercare e interrogare lo stesso contenuto con campi e strumenti tuoi.

> 🇬🇧 A metadata-first file manager for macOS: enrich real files and folders with custom columns (notes, numbers, dates, Kanban, tags, links) without ever moving or altering them. Optional on-device AI adds content indexing (with OCR), hybrid semantic search and a RAG chat over your documents that cites its sources. UI in Italian and English. MIT licensed — free to use, fork and build.

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

### Organizzazione per metadata
- Sidebar con cartelle recenti, albero della struttura, **pannello dettagli** (inspector) e Configurazione a sezioni.
- Tabella nativa con colonne standard (Nome, Tipo, Creato, Dimensioni) + colonne **metadata per-cartella**.
- Tipi di colonna: **nota libera, numero, data, Kanban, Select** (tag colorati) e **link** (URL, file locali, markdown e wiki link `[[…]]`).
- **Template** di colonne riutilizzabili, applicabili con un clic a cartelle nuove.
- Vista **Kanban a board** con drag tra colonne.
- Ricerca, filtri a chip, ordinamento, selezione multipla e **modifica in blocco**, export **CSV**.
- I metadata seguono i file su **rename e spostamenti** (identità basata sugli identificatori filesystem di macOS).

### Funzioni AI (opzionali, opt-in)
- **Indicizzazione dei contenuti** di cartella e sottocartelle, con **OCR** per PDF scansionati e immagini; reindicizzazione incrementale.
- **Ricerca per contenuto** ibrida (parole esatte + significato).
- **Chat con i documenti** (RAG) con retrieval ibrido, citazione delle fonti, disambiguazione di versioni e ambito selezionabile (indice / cartella / file).
- **Motori intercambiabili**: embedding su questo Mac (Apple, gratis e privato), locale (Ollama) o cloud (OpenAI, BYOK con chiave nel Portachiavi); chat via Ollama o OpenAI.
- Interruttore generale: da spento, la chat sparisce e la ricerca torna al solo nome.

### Sistema
- **Backup e ripristino** del database, con backup automatici pianificabili.
- **Avvio al login** del Mac e **icona nella barra dei menu** per riaprire rapidamente le cartelle.
- **Manutenzione** del DB: riallineamento e pulizia degli orfani (anche automatica).
- Tema chiaro / scuro / automatico, dimensione caratteri e **colore d'accento** regolabili.
- Controllo **aggiornamenti** su GitHub all'avvio.
- **Interfaccia in Italiano e Inglese**, con guida d'uso integrata (Configurazione → Aiuto).
- Salvataggio locale e non invasivo in `~/Library/Application Support/FolderBase/folderbase.sqlite`: le tue cartelle non vengono mai modificate.

---

## Privacy

Con il motore di embedding **Apple** (su questo Mac) e la chat **Ollama** (locale), nessun dato lascia il tuo Mac. Se scegli **OpenAI** per embedding o chat, le domande e gli estratti dei file vengono inviati a OpenAI; la chiave API è custodita nel Portachiavi di macOS. Con l'interruttore AI spento, nessuna funzione di intelligenza artificiale è attiva.

---

## Stack

Swift · SwiftUI · Swift Package Manager · SQLite (metadata, indice e embedding locali; FTS5 per il full-text) · FileManager / AppKit · Vision (OCR) · FSEvents · SMAppService.

Struttura del codice e dettagli architetturali nel **[MANUALE.md](MANUALE.md)**. Guida rapida in **[COME_TROVARE_E_USARE.md](COME_TROVARE_E_USARE.md)**.

---

## Contribuire

Il progetto è open source con licenza MIT: sei libero di **usarlo, modificarlo, forkarlo e ridistribuirlo**. Issue e pull request sono benvenute.

## Licenza

Distribuito con licenza **MIT** — vedi il file [LICENSE](LICENSE). © 2026 Paolo Sturbini.
