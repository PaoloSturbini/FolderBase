# FolderBase — Studio di fattibilità: indicizzazione AI, OCR e ricerca semantica

_Studio tecnico, luglio 2026. Ancorato all'architettura attuale (SQLite, identità file stabile per inode, app non-sandboxed, macOS 14.4)._

## 1. Obiettivo

Aggiungere a FolderBase la capacità di **capire il contenuto** dei file (non solo i metadata manuali) e di **cercarli per significato**, mantenendo la filosofia "metadata-first" e locale. Tre capacità distinte ma incatenate:

1. **Estrazione testo + OCR** — trasformare ogni file (PDF, immagine, doc, testo) in testo grezzo.
2. **Embedding** — trasformare quel testo in vettori tramite un modello AI (a scelta dell'utente: BYOK cloud, endpoint locale, o on-device Apple).
3. **Ricerca semantica vettoriale** — trovare i file per similarità di significato, non per corrispondenza di stringa.

Il punto di forza rispetto a Spotlight/Finder: la ricerca vive **dentro** il DB che già contiene i metadata per-cartella, quindi si può combinare "documenti simili a questo concetto" **con** i filtri metadata esistenti (Kanban, Select, date).

## 2. I tre pilastri e le scelte di provider

L'idea centrale è un **unico protocollo Swift** dietro cui stanno provider intercambiabili. L'app non deve sapere se l'embedding arriva da OpenAI, da Ollama in locale o dal framework Apple.

```swift
protocol EmbeddingProvider {
    var identifier: String { get }        // "openai", "ollama", "apple-nl"
    var dimension: Int { get }            // 1536, 768, 512...
    func embed(_ texts: [String]) async throws -> [[Float]]
}

protocol TextExtractor {
    /// Ritorna testo grezzo + flag "ocrUsed". nil se il tipo non è supportato.
    func extractText(from url: URL) async throws -> ExtractedText?
}
```

### 2.1 Provider di embedding — confronto

| Opzione | Come | Pro | Contro | Dimensioni |
|---|---|---|---|---|
| **BYOK cloud** (OpenAI `text-embedding-3-small/large`, Voyage, Cohere, Mistral) | `URLSession` POST a endpoint REST, chiave in Keychain | Qualità alta, zero setup di modelli, batch grandi | I contenuti dei file escono dal Mac (privacy), costo per token, richiede rete | 512–3072 |
| **Endpoint locale** (Ollama `nomic-embed-text`/`mxbai-embed-large`, LM Studio, llama.cpp server) | POST a `http://localhost:11434/api/embeddings` | Privato, gratuito, offline, stesso codice REST del BYOK | L'utente deve installare/avviare un server; usa RAM/CPU | 768–1024 |
| **On-device Apple** (`NLContextualEmbedding` del framework NaturalLanguage, disponibile da macOS 14) | API nativa, nessuna rete | Zero dipendenze, zero costo, privato, sempre disponibile | Qualità semantica inferiore ai modelli dedicati, multilingua più debole | ~512–768 |

**Raccomandazione**: partire con **on-device Apple** come default "funziona-subito" (nessuna configurazione, coerente con un'app scaricata da GitHub non notarizzata) e offrire **Ollama** e **BYOK** come opzioni avanzate. Tutti e tre implementano lo stesso `EmbeddingProvider`, quindi il resto della pipeline non cambia.

> Nota architetturale importante: **la dimensione del vettore fa parte dell'identità dell'indice**. Cambiare provider (es. da 768 a 1536) invalida tutti gli embedding già calcolati. Va salvato `provider_id` + `dimension` nell'indice e gestito il "reindex" al cambio.

### 2.2 OCR ed estrazione testo — tutto nativo macOS

Non serve alcun provider esterno per l'estrazione: lo stack Apple copre quasi tutto, on-device e gratis.

- **Testo semplice / Markdown / codice**: lettura diretta (`String(contentsOf:)`), con rilevamento encoding.
- **PDF con testo**: `PDFKit` (`PDFDocument.string`) — istantaneo, nessun OCR.
- **PDF scansionati / immagini** (`.png`, `.jpg`, `.heic`, `.tiff`): **Vision** `VNRecognizeTextRequest` (`.accurate`, `recognitionLanguages = ["it-IT","en-US"]`). Da macOS 15 c'è anche `RecognizeDocumentsRequest` che preserva struttura/tabelle — usarlo se disponibile via `#available`.
- **Office** (`.docx`, `.pptx`, `.xlsx`): unzip dell'OOXML ed estrazione dei nodi di testo dall'XML (nessuna libreria pesante), oppure conversione via `NSAttributedString`.
- **RTF / HTML**: `NSAttributedString(url:)`.

L'OCR è il passo costoso: va fatto **una sola volta per file**, in background, e il testo va messo in cache (vedi §4). Vision lavora su `CGImage`; per i PDF scansionati si renderizza ogni pagina con `PDFPage.thumbnail`/Core Graphics e la si passa a Vision.

## 3. Storage vettoriale dentro SQLite

FolderBase ha già SQLite (`folderbase.sqlite`, WAL, `synchronous=NORMAL`). Due strade:

### 3.1 Opzione A — estensione `sqlite-vec` (consigliata)

[`sqlite-vec`](https://github.com/asg017/sqlite-vec) è un'estensione C single-file, senza dipendenze, con virtual table `vec0`, distanze (cosine/L2) e KNN SIMD-accelerato. Si compila in un `.dylib` (o si linka staticamente) e si carica con `sqlite3_load_extension`. È il fit naturale: gli embedding restano **nello stesso DB** dei metadata, quindi una singola query può fare join tra similarità vettoriale e filtri metadata.

```sql
CREATE VIRTUAL TABLE vec_chunks USING vec0(
    chunk_id INTEGER PRIMARY KEY,
    embedding FLOAT[768]
);
-- KNN:
SELECT chunk_id, distance FROM vec_chunks
WHERE embedding MATCH ? ORDER BY distance LIMIT 20;
```

Costo di integrazione: aggiungere il sorgente C al target (o linkare la lib, come già si fa con `-l sqlite3` in `Package.swift`), abilitare il caricamento estensioni. Poiché l'app **non è sandboxed**, caricare un'estensione è fattibile senza entitlement speciali.

### 3.2 Opzione B — BLOB + cosine in Swift (zero dipendenze)

Salvare ogni vettore come `BLOB` (Float32 impacchettati) in una tabella normale e calcolare la similarità coseno in Swift, accelerata con **Accelerate/`vDSP`**. Fino a ~10⁴–10⁵ chunk è più che sufficiente (scan lineare in pochi ms con vDSP). Vantaggio: nessuna estensione da compilare/distribuire, coerente con la scelta minimalista del progetto. Svantaggio: niente ANN, scala peggio oltre ~100k chunk.

**Raccomandazione**: iniziare con **B** (nessun rischio di distribuzione, si spedisce subito) e passare ad **A** solo se/quando il volume lo richiede. Lo strato `VectorStore` va dietro un protocollo così lo swap è trasparente:

```swift
protocol VectorStore {
    func upsert(chunkID: Int64, vector: [Float]) throws
    func search(_ query: [Float], limit: Int) throws -> [(chunkID: Int64, score: Float)]
    func delete(fileIdentity: String) throws
}
```

### 3.3 Estensione dello schema esistente

Nuove tabelle, **additive** (nessuna modifica a `files`/`metadata_fields`/`metadata_values`), create in `migrateSchema()` accanto alle attuali:

```sql
-- Testo estratto + stato indicizzazione, una riga per file gestito.
CREATE TABLE IF NOT EXISTS file_content (
    file_identity TEXT PRIMARY KEY REFERENCES files(identity) ON DELETE CASCADE,
    extracted_text TEXT,
    ocr_used INTEGER NOT NULL DEFAULT 0,
    content_hash TEXT,          -- hash del file: se cambia → reindex
    extracted_at REAL,
    index_state TEXT NOT NULL DEFAULT 'pending' -- pending|extracted|embedded|error
);

-- Chunk di testo (i documenti lunghi si spezzano): un embedding per chunk.
CREATE TABLE IF NOT EXISTS content_chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_identity TEXT NOT NULL REFERENCES files(identity) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    text TEXT NOT NULL
);

-- Vettori: BLOB (opzione B) oppure virtual table vec0 (opzione A).
CREATE TABLE IF NOT EXISTS chunk_vectors (
    chunk_id INTEGER PRIMARY KEY REFERENCES content_chunks(id) ON DELETE CASCADE,
    provider_id TEXT NOT NULL,
    dimension INTEGER NOT NULL,
    vector BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chunks_file ON content_chunks(file_identity);
```

Questo si sposa perfettamente con il modello di identità esistente: la chiave è sempre `files.identity` (inode-based), quindi **spostamenti e rinomini sullo stesso volume mantengono l'indice** senza reindicizzare, esattamente come già fanno i metadata. La cancellazione di un file (via `purgeOrphans`/reconcile) rimuove i vettori in cascata (`ON DELETE CASCADE`).

## 4. Pipeline di indicizzazione

Deve rispettare gli invarianti di performance già stabiliti (vedi `folderbase-performance-architecture`): **niente lavoro pesante sul main thread, niente nel percorso caldo di navigazione**.

Flusso, tutto su un `IndexingService` con `actor`/coda seriale in background:

1. **Trigger**: l'utente attiva l'indicizzazione su una cartella gestita (opt-in esplicito, mai automatico su tutto il disco). Enumerazione incrementale.
2. **Dedup/skip**: per ogni file calcola `content_hash` (es. size + mtime, o SHA dei primi/ultimi KB per file grandi). Se combacia con `file_content.content_hash` → skip.
3. **Estrazione** (`TextExtractor`): testo + `ocr_used`. Salva in `file_content`, stato `extracted`. Questo è il passo lento (OCR): throttling, e va interrotto se la cartella cambia.
4. **Chunking**: spezza il testo in blocchi ~500–1000 token con overlap, scrive `content_chunks`.
5. **Embedding** (`EmbeddingProvider`): in batch (cloud/Ollama accettano array); scrive `chunk_vectors`, stato `embedded`.
6. **Aggiornamento incrementale**: agganciarsi al già esistente `FSEventsWatcher` — quando un file gestito cambia, marca `index_state='pending'` e ricalcola solo quello. Il reconcile esistente (`reconcileManagedFiles`) gestisce già relocate/missing: basta estenderlo per invalidare l'indice degli orfani.

Concorrenza: OCR ed embedding sono I/O e CPU bound → `TaskGroup` con parallelismo limitato (es. 2–4). Persistenza a batch con lo stesso pattern debounce già usato in `MetadataStore` (`scheduleWrite`). Progress osservabile in UI (una barra tipo la card "Manutenzione" già presente).

## 5. Ricerca semantica — UX

Due modalità, entrambe innestabili nella barra di ricerca esistente di `FileTableView` (`searchText`):

- **Ricerca per query**: l'utente scrive una frase → si calcola l'embedding della query con lo stesso provider → KNN sui `chunk_vectors` → si raggruppano i chunk per `file_identity`, si prende il best score per file → si ordina. Risultato: lista di file con snippet del chunk più rilevante evidenziato.
- **"Trova simili a questo"**: voce di menu contestuale su un file (accanto a Apri/QuickLook) → usa gli embedding già calcolati di quel file come query. Naturale evoluzione dei metadata: "documenti che parlano di questo".

Punto chiave: la ricerca vettoriale **coesiste** con i filtri esistenti. Poiché tutto è in SQLite, una query può fare `JOIN` tra i risultati KNN e `metadata_values` — es. "fatture simili a questa **E** con Kanban = Da pagare". Questo è il vero differenziatore rispetto a Spotlight.

UI: aggiungere un toggle "Ricerca: nome / contenuto (AI)" accanto al campo di ricerca. Rispettare l'invariante n.1 di performance: ogni nuovo stato che influenza il filtro deve chiamare `refreshDisplayCache()`. La query di embedding è async → si aggiorna una `@State cachedSemanticResults` e si fa refresh al completamento (mai bloccare la digitazione).

## 6. Chat con i propri file (RAG)

Oltre a cercare, l'utente deve poter **conversare** con i propri documenti — "riassumi questo contratto", "in quali file si parla di rinnovo automatico?", "quali fatture scadono a luglio?". È il passo naturale sopra la ricerca semantica: si chiama **RAG** (Retrieval-Augmented Generation) e riusa **tutto** ciò che è già in piedi (estrazione, chunk, embedding, vector store). L'unica capacità nuova è la **generazione di testo** da parte di un LLM.

### 6.1 Stesso strato provider, capacità aggiuntiva

Il provider AI configurato (BYOK / Ollama / on-device) espone, oltre agli embedding, anche la generazione. Un secondo protocollo affianca `EmbeddingProvider`:

```swift
protocol ChatProvider {
    var identifier: String { get }
    var supportsStreaming: Bool { get }
    /// Risposta in streaming (token-by-token) per una UI reattiva.
    func chat(messages: [ChatMessage], context: [RetrievedChunk]) -> AsyncThrowingStream<String, Error>
}
```

- **BYOK cloud**: OpenAI (`gpt-*`), Anthropic (`claude-*`), Mistral, ecc. — stesso endpoint REST/chiave in Keychain del provider di embedding.
- **Endpoint locale**: Ollama (`llama3.1`, `qwen2.5`, `mistral`) via `http://localhost:11434/api/chat`, o LM Studio — privato e offline.
- **On-device Apple**: il **Foundation Models framework** (macOS 26+, `SystemLanguageModel`/`LanguageModelSession`) dà un LLM on-device con API Swift nativa e generazione guidata. Ideale come default privato dove disponibile; con `#available` fallback ai provider precedenti sulle versioni più vecchie.

> Un utente potrebbe voler **embedding on-device** ma **chat cloud** (o viceversa). Conviene tenere le due configurazioni **indipendenti** nel pannello impostazioni.

### 6.2 Flusso RAG

1. **Domanda** dell'utente in una nuova UI di chat (finestra/pannello laterale).
2. **Retrieval**: si calcola l'embedding della domanda (stesso `EmbeddingProvider` dell'indice) → KNN sui `chunk_vectors` → si prendono i top-k chunk più rilevanti. Opzionale: **query ibrida** (vettori + FTS della Fase 0 con Reciprocal Rank Fusion) per catturare sia significato sia parole esatte.
3. **Filtro di scope**: l'utente sceglie l'ambito — cartella corrente, selezione di file, o tutto l'indicizzato. Tradotto in un `WHERE` sui `file_identity`, coerente col modello per-cartella.
4. **Prompt**: si costruisce il contesto concatenando i chunk recuperati con la loro provenienza (nome file + path), dentro un system prompt che impone di **rispondere solo dal contesto e citare le fonti**.
5. **Generazione** (`ChatProvider`) in **streaming**: la risposta appare token-by-token.
6. **Citazioni**: ogni chunk usato porta il suo `file_identity` → in risposta si mostrano i file sorgente **cliccabili** (aprono/rivelano nel Finder, QuickLook — riusando le azioni già esistenti in `FileTableView`).

### 6.3 UX e vincoli

- Ingresso naturale: pulsante "Chatta con questi file" nella toolbar della tabella (ambito = cartella/selezione) e voce nel menu contestuale.
- **Streaming su background**, mai bloccare il main thread; l'`AsyncThrowingStream` aggiorna una `@State` di conversazione. Rispetta gli stessi invarianti di `MetadataStore`/`FileTableView`.
- **Gestione del limite di contesto**: troncare/riordinare i chunk per rientrare nella finestra del modello; per modelli locali piccoli, ridurre top-k.
- **Trasparenza dati**: con provider cloud, il contenuto dei chunk recuperati viene inviato all'LLM — avviso esplicito, come per gli embedding. Default on-device dove possibile.
- **Nessun indice = nessuna chat**: la chat richiede che la cartella sia già stata indicizzata (Fase 1). Se non lo è, offrire di indicizzarla al volo.

## 7. Mappatura concreta sui file del progetto

| Cosa | Dove | Tipo di intervento |
|---|---|---|
| Schema `file_content`/`content_chunks`/`chunk_vectors` | `Services/MetadataStore.swift` → `migrateSchema()` | Additivo, come `addColumnIfMissing` già usato |
| `EmbeddingProvider` + implementazioni | nuovo `Services/AI/EmbeddingProvider.swift`, `OllamaProvider.swift`, `OpenAIProvider.swift`, `AppleNLProvider.swift` | Nuovi file |
| `ChatProvider` (LLM streaming) + implementazioni | nuovo `Services/AI/ChatProvider.swift` (+ Ollama/OpenAI/Anthropic/FoundationModels) | Nuovi file |
| Servizio RAG (retrieval + prompt + citazioni) | nuovo `Services/AI/ChatService.swift` | Nuovo file, riusa `VectorStore` |
| UI chat (pannello/finestra, streaming, fonti cliccabili) | nuovo `UI/ChatView.swift` + pulsante in `FileTableView` | Nuovi/estensione |
| `TextExtractor` (Vision/PDFKit/OOXML) | nuovo `Services/AI/TextExtractor.swift` | Nuovo file, `import Vision`/`PDFKit` |
| `VectorStore` (BLOB+vDSP, poi sqlite-vec) | nuovo `Services/AI/VectorStore.swift` | Nuovo file |
| Orchestrazione (coda, progress, aggancio FSEvents) | nuovo `Services/AI/IndexingService.swift` | Nuovo file; wiring in `MainWindowView` accanto a `refreshManagedWatcher` |
| Chiave API in Keychain | nuovo `Services/AI/APIKeyStore.swift` | Nuovo file (`Security` framework) |
| UI impostazioni AI (provider, chiave, reindex, progress) | `UI/SidebarView.swift` | Nuova `SettingsSection` `.ai`, coerente con le sezioni esistenti (Aiuto, Manutenzione…) |
| Toggle + risultati ricerca semantica | `UI/FileTableView.swift` | Estensione di `searchText`/`refreshDisplayCache` |
| Voce "Trova simili" / "Chatta con questi file" | `UI/FileTableView.swift` menu contestuale + toolbar | Additivo |
| Localizzazione IT/EN nuove chiavi | `Services/Localization.swift` | `ai.*`, `search.semantic.*`, `chat.*` (non tradurre i rawValue persistiti) |
| Linking `sqlite-vec` (solo opzione A) | `Package.swift` | Come già `-l sqlite3` |

## 8. Privacy, sicurezza, distribuzione

- **Chiave BYOK**: mai in `UserDefaults`/JSON. Usare **Keychain** (`kSecClassGenericPassword`). Nel pannello mostrare solo "configurata / non configurata".
- **Trasparenza dati**: se il provider è cloud, avvisare chiaramente che il **contenuto** dei file (non solo i nomi) viene inviato all'endpoint. Default on-device proprio per evitarlo.
- **Opt-in per cartella**: l'indicizzazione non deve mai partire da sola sull'intero disco. Coerente col modello "metadata per-cartella".
- **App non-sandboxed + non notarizzata**: caricare `sqlite-vec` come `.dylib` e fare chiamate rete a `localhost`/cloud è possibile senza entitlement, ma se un domani si volesse notarizzare/App Store servirebbero entitlement rete e revisione del caricamento estensioni (in tal caso preferire l'opzione B pura Swift o linking statico).
- **Costi**: con BYOK, mostrare una stima ("~N documenti, ~M token") prima di lanciare un reindex massivo; per la chat, il costo è per conversazione (contesto + risposta).

## 9. Roadmap incrementale

Ogni fase è spedibile da sola e verificabile con `make-app.sh -c release`.

- **Fase 0 — Estrazione + full-text search (senza AI).** `TextExtractor` + tabella `file_content` + FTS5 di SQLite. Dà subito "cerca dentro i file" con OCR, zero provider esterni, zero vettori. Valore immediato, rischio minimo.
- **Fase 1 — Embedding on-device + ricerca semantica (opzione B).** `AppleNLProvider` + `VectorStore` BLOB/vDSP + chunking + UI toggle. Tutto locale, nessuna dipendenza nuova.
- **Fase 2 — Provider intercambiabili.** `OllamaProvider` (locale potente) e `OpenAIProvider` (BYOK) + Keychain + pannello impostazioni + gestione reindex al cambio dimensione.
- **Fase 3 — Chat con i file (RAG).** `ChatProvider` + `ChatService` (retrieval → prompt → generazione in streaming con citazioni) + `ChatView`. Riusa l'indice della Fase 1/2; ambito per cartella/selezione; provider chat indipendente da quello embedding.
- **Fase 4 — Scala e qualità.** Passaggio a `sqlite-vec` per grandi volumi; query ibride (vettore + filtri metadata + FTS, RRF); "Trova simili"; ranking migliorato; memoria conversazione multi-turn.

## 10. Rischi e caveat

- **Reindex al cambio provider/dimensione**: da gestire esplicitamente, altrimenti risultati incoerenti. Salvare `provider_id`+`dimension` per chunk e ricalcolare i disallineati.
- **Costo OCR su cartelle grandi**: throttling, progress annullabile, hash per non rifare lavoro. È il vero collo di bottiglia, non l'embedding.
- **Qualità multilingua on-device**: `NLContextualEmbedding` è più debole dei modelli dedicati su testi misti IT/EN; se la qualità delude, Ollama (`nomic-embed-text`) è l'upgrade locale naturale.
- **API non testabili nel sandbox Linux**: Vision, PDFKit, NaturalLanguage, Foundation Models, Keychain, caricamento estensioni SQLite → la verifica build va fatta sul Mac (workflow `make-app.sh -c release` già collaudato).
- **Chat — allucinazioni e finestra di contesto**: imporre nel system prompt di rispondere solo dal contesto recuperato e citare le fonti; troncare i chunk per rientrare nella finestra del modello (critico coi modelli locali piccoli). La qualità della chat dipende dalla qualità del retrieval, quindi dagli embedding scelti.
- **Coerenza con gli invarianti performance esistenti**: niente embedding/OCR sul main thread; ogni nuovo stato di ricerca deve triggerare `refreshDisplayCache()`; le scritture vettoriali seguono il pattern debounce di `MetadataStore`.

---

### Sintesi in una riga

Aggiungere servizi disaccoppiati (`TextExtractor` nativo Vision/PDFKit, `EmbeddingProvider` e `ChatProvider` con default on-device + Ollama/BYOK opzionali e indipendenti, `VectorStore` prima BLOB+vDSP poi `sqlite-vec`), tre tabelle additive in SQLite chiavate su `files.identity`, e una pipeline in background agganciata a `FSEventsWatcher`. Sulla stessa base — recupero dei chunk per similarità → prompt con citazioni → generazione in streaming — si costruisce la **chat con i propri file**. Spedibile in 5 fasi, partendo da full-text+OCR senza alcuna AI esterna e arrivando a ricerca semantica e chat RAG.
