# Ottimizzazioni performance — branch `perf/hot-paths`

Data: 2026-07-13 · Target: macOS 14.4 · Base: `main` @ `171fec9`

Quattro ottimizzazioni ad alto impatto sui percorsi caldi + un filtro di indicizzazione
che evita lavoro inutile. Nessun cambiamento all'interfaccia o al formato dati persistito;
le connessioni SQLite restano due (main + `SQLiteDatabaseActor`) cooperanti via WAL.

## 1. `PRAGMA synchronous = NORMAL` sull'actor SQLite

`SQLiteDatabaseActor` impostava WAL, `cache_size` e `temp_store` ma restava a
`synchronous = FULL` (default), pur essendo la connessione che esegue le scritture più
pesanti (testo estratto, chunk, vettori di embedding). Ogni `COMMIT` faceva un fsync
completo. Impostando `NORMAL` — sicuro sotto WAL, come già faceva la connessione main —
il costo dei commit durante l'indicizzazione è circa dimezzato.

## 2. Cache di prepared statement

Prima ogni scrittura ricompilava l'SQL con `sqlite3_prepare_v2` + `sqlite3_finalize`.
Introdotta una cache `[String: OpaquePointer]` su entrambe le connessioni:

- `SQLiteDatabaseActor`: gli statement dei loop caldi (`upsertMetadata`,
  `applyTrackingUpdates`, insert di chunk e vettori in `replaceChunks`/`storeContent`,
  `scalarText`) vengono riusati con `sqlite3_reset` + `sqlite3_clear_bindings`.
- `MetadataStore`: nuovi helper `cachedStatement`/`executeCached`, usati da `persistValue`
  (percorso per-keystroke).

Gli statement in cache vengono finalizzati in `close()`/`deinit` (e prima della
sostituzione del DB in `restore`).

## 3. Reconcile FSEvents mirato

`reconcileManagedFiles` ignorava i `changedPaths` di FSEvents: caricava tutte le righe
gestite e per ognuna risolveva il bookmark + `stat` su disco — una scansione O(N)
dell'intero archivio a ogni singolo evento (anche il touch di un file).

Aggiunto il parametro `changedPaths:`. Se valorizzato, la riconciliazione è **mirata**:
risolve solo le righe il cui percorso ricade sotto uno dei path cambiati. Passando `nil`
(default) si forza il full reconcile, usato all'avvio quando non si sa cosa sia cambiato
mentre l'app era chiusa. Il callback FSEvents in `MainWindowView` ora passa `changedPaths`.

## 4. Ricerca semantica RAG fuori dal main thread

Il `Task` in `ChatService.run` eredita `@MainActor`, quindi embedding, scansione vettoriale
e scoring giravano tutti sul main thread, bloccando la UI a ogni domanda con costo lineare
sul numero di chunk.

- La scansione dei vettori + decodifica dei BLOB si spostano su
  `SQLiteDatabaseActor.semanticRows(candidates:querySpaces:)` (connessione di background).
  Il vettore viene decodificato **solo** per gli spazi-query (gli altri chunk servono
  comunque al punteggio lessicale su testo/nome): evita di deserializzare BLOB inutili.
- Lo scoring diventa `MetadataStore.rankSemanticChunks` — `nonisolated static`, calcolo
  puro — eseguito in un `Task.detached`. `floats`/`norm`/`cosine` sono ora `nonisolated`;
  `RetrievedChunk` e `SemanticRow` sono `Sendable`.
- `ChatService` usa `store.semanticChunksAsync` / `indexedProviderIDsAsync`.
- Il vecchio `semanticChunks` sincrono resta come fallback se l'actor non è disponibile.

## 5. Filtro di indicizzazione: solo contenuti indicizzabili

Prima la pipeline tentava l'estrazione su **ogni** file regolare (compresi video, audio,
archivi, immagini disco, binari): lavoro sprecato, e i file non testuali tenevano la
copertura di una cartella bloccata sotto il 100%.

- `TextExtractor.isIndexableCandidate(url)` (+ `nonIndexableExtensions`) è l'unica fonte
  di verità su cosa è plausibilmente estraibile (testo/PDF/Office/immagini via OCR),
  allineata ai formati realmente gestiti da `extractText`.
- `indexableURLs`/`fileItems`/`fingerprints` hanno il parametro `contentOnly`
  (default `false`): la **ricerca per nome** continua a vedere TUTTI i file del sottoalbero.
- L'indicizzazione (`indexRecursively`, `status`, e come rete di sicurezza `runLoop`) usa
  `contentOnly: true`: i file inutili non vengono accodati né contati nel denominatore
  della copertura. Una cartella piena di video non resta più "arancione" per sempre.

## Verifica

- `swift build -c release`: pulito.
- Bundle installato via `./make-app.sh -c release` in `/Applications/FolderBase.app`.

## Invarianti da rispettare in futuro

- Non reintrodurre `prepare` + `finalize` nei loop caldi: usare la cache.
- La ricerca semantica pesante deve restare fuori dal main (actor + `Task.detached`).
- Il filtro `contentOnly` vale solo per la pipeline di indicizzazione, mai per la ricerca.
