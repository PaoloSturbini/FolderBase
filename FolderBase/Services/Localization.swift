import Foundation
import Combine

/// Lingua dell'interfaccia. Il rawValue è anche la chiave salvata nei preferiti.
enum AppLanguage: String, CaseIterable, Identifiable {
    case italian = "it"
    case english = "en"

    var id: String { rawValue }

    /// Nome mostrato nel selettore (sempre nella lingua stessa, come da convenzione macOS).
    var displayName: String {
        switch self {
        case .italian:
            return "Italiano"
        case .english:
            return "English"
        }
    }
}

/// Gestore centrale della lingua. È un `ObservableObject` singleton: le viste che lo
/// osservano si ridisegnano quando la lingua cambia, così la traduzione è immediata
/// (senza riavviare l'app). La scelta è persistente in `UserDefaults`.
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    static let storageKey = "appLanguage"

    @Published var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let stored = AppLanguage(rawValue: raw) {
            language = stored
        } else {
            // Default: italiano (comportamento storico dell'app).
            language = .italian
        }
    }
}

/// Traduce una chiave nella lingua corrente. Se la chiave non esiste, restituisce la
/// chiave stessa (così un'eventuale dimenticanza è subito visibile).
func L(_ key: String) -> String {
    LocalizedStrings.string(key, language: LocalizationManager.shared.language)
}

enum LocalizedStrings {
    static func string(_ key: String, language: AppLanguage) -> String {
        guard let entry = table[key] else { return key }
        switch language {
        case .italian:
            return entry.it
        case .english:
            return entry.en
        }
    }

    // Chiave → (italiano, inglese).
    static let table: [String: (it: String, en: String)] = [
        // MARK: Generale
        "common.cancel": ("Annulla", "Cancel"),
        "common.save": ("Salva", "Save"),
        "common.add": ("Aggiungi", "Add"),
        "common.create": ("Crea", "Create"),
        "common.apply": ("Applica", "Apply"),
        "common.done": ("Fine", "Done"),
        "common.name": ("Nome", "Name"),
        "common.value": ("Valore", "Value"),
        "common.type": ("Tipo", "Type"),
        "common.color": ("Colore", "Color"),
        "common.empty": ("<vuoto>", "<empty>"),
        "common.noFolders": ("Nessuna cartella", "No folders"),

        // MARK: Sidebar
        "sidebar.folders": ("Cartelle", "Folders"),
        "sidebar.structure": ("Struttura", "Structure"),
        "sidebar.notes": ("Note", "Notes"),
        "sidebar.details": ("Dettagli", "Details"),
        "notes.noSelection": ("Seleziona un file per vederne i dettagli.", "Select a file to see its details."),
        "notes.empty": ("Nessuna nota per questo elemento.", "No notes for this item."),
        "sidebar.removeFolder": ("Togli cartella", "Remove folder"),
        "sidebar.configuration": ("Configurazione", "Settings"),

        // MARK: Sezioni configurazione
        "settings.folders.title": ("Cartelle", "Folders"),
        "settings.appearance.title": ("Aspetto", "Appearance"),
        "settings.display.title": ("Visualizzazione", "Display"),
        "settings.startup.title": ("Avvio", "Startup"),
        "settings.language.title": ("Lingua", "Language"),
        "settings.templates.title": ("Template", "Templates"),
        "settings.indexing.title": ("Funzioni di A.I.", "A.I. Features"),
        "settings.maintenance.title": ("Manutenzione", "Maintenance"),
        "settings.backup.title": ("Backup", "Backup"),
        "settings.help.title": ("Aiuto", "Help"),
        "settings.support.title": ("Info su FolderBase", "About FolderBase"),

        "settings.folders.subtitle": ("Cartelle monitorate e recenti", "Tracked folders and recents"),
        "settings.appearance.subtitle": ("Tema e dimensione dei caratteri", "Theme and font size"),
        "settings.display.subtitle": ("Opzioni di visualizzazione della tabella", "Table display options"),
        "settings.startup.subtitle": ("Comportamento all'avvio del Mac", "Behavior at Mac startup"),
        "settings.language.subtitle": ("Lingua dell'interfaccia", "Interface language"),
        "settings.templates.subtitle": ("Insiemi di colonne riutilizzabili", "Reusable sets of columns"),
        "settings.indexing.subtitle": ("Indicizzazione contenuti per la ricerca", "Content indexing for search"),
        "settings.maintenance.subtitle": ("Sincronizzazione e pulizia dei metadata", "Metadata sync and cleanup"),

        // MARK: Indicizzazione (sezione)
        "indexing.card": ("Indicizzazione contenuti", "Content indexing"),
        "indexing.intro": ("Estrae il testo dei file della cartella e di tutte le sottocartelle (con OCR per PDF scansionati e immagini) e ne calcola gli embedding, per abilitare la ricerca per contenuto e per significato. Fallo una volta: al successivo avvio verranno reindicizzati solo i file cambiati.", "Extracts the text of the files in the folder and all subfolders (with OCR for scanned PDFs and images) and computes their embeddings, enabling content and semantic search. Do it once: next time only changed files are re-indexed."),
        "indexing.button": ("Indicizza cartella e sottocartelle", "Index folder and subfolders"),
        "indexing.reindex": ("Aggiorna indicizzazione", "Update index"),
        "indexing.noFolder": ("Nessuna cartella selezionata", "No folder selected"),
        "indexing.scanning": ("Analisi cartella…", "Scanning folder…"),
        "indexing.status.checking": ("Verifica stato…", "Checking status…"),
        "indexing.status.unknown": ("Stato non calcolato", "Status not computed"),
        "indexing.status.notIndexed": ("Non indicizzata", "Not indexed"),
        "indexing.status.upToDate": ("Indicizzata", "Indexed"),
        "indexing.status.stale": ("Da aggiornare", "Needs update"),
        "indexing.recheck": ("Ricalcola stato", "Recheck status"),
        "indexing.checkedAt": ("verificato", "checked"),
        "indexing.embedFailures": ("Embedding NON riuscito per", "Embedding FAILED for"),
        "indexing.embedFailures.hint": ("Verifica che il motore sia in esecuzione (es. Ollama) e l'URL in \u{201C}Motore AI\u{201D}, poi rilancia l'indicizzazione. I testi sono salvati: verranno creati solo i vettori mancanti.", "Check that the engine is running (e.g. Ollama) and the URL in \u{201C}AI Engine\u{201D}, then re-run indexing. Texts are saved: only the missing vectors will be created."),
        "indexing.embedFailures.engineDown": ("Causa: il MOTORE di embedding non è raggiungibile — il problema non riguarda i file", "Cause: the embedding ENGINE is unreachable — the files themselves are fine"),
        "indexing.embedFailures.fileSpecific": ("Il motore di embedding è raggiungibile: il problema riguarda questi FILE specifici (contenuto non elaborabile dal modello o errore temporaneo). Rilancia l'indicizzazione; se fallisce ancora sugli stessi file, i loro contenuti restano comunque cercabili per parole chiave.", "The embedding engine is reachable: the problem is with these specific FILES (content the model could not process, or a transient error). Re-run indexing; if it keeps failing on the same files, their contents remain searchable by keywords."),
        "indexing.embedFailures.failedList": ("File interessati:", "Affected files:"),
        "indexing.embedFailures.andMore": ("e altri", "and"),

        // MARK: Icona nella barra dei menu
        "display.menuBarIcon": ("Icona nella barra dei menu", "Menu bar icon"),
        "display.menuBarIconNote": ("Mostra un'icona nella barra dei menu del Mac: puoi chiudere o ridurre la finestra e riaprirla da lì direttamente su una delle cartelle disponibili.", "Shows an icon in the Mac menu bar: you can close or minimize the window and reopen it from there directly on one of the available folders."),
        "startup.card": ("Avvio", "Startup"),
        "display.launchAtLogin": ("Avvia all'accesso al Mac", "Launch at Mac login"),
        "display.launchAtLoginNote": ("Apre automaticamente FolderBase quando accedi al tuo account sul Mac.", "Automatically opens FolderBase when you log in to your account on the Mac."),
        "menubar.foldersHeader": ("Apri cartella", "Open folder"),
        "menubar.openApp": ("Apri FolderBase", "Open FolderBase"),
        "menubar.quit": ("Esci da FolderBase", "Quit FolderBase"),

        // MARK: Diagnosi motore di embedding (health check)
        "engine.health.badURL": ("URL del motore non valido:", "Invalid engine URL:"),
        "engine.health.ollamaDown": ("Ollama non risponde su", "Ollama is not responding at"),
        "engine.health.modelMissing": ("Ollama è attivo ma il modello di embedding non è installato:", "Ollama is running but the embedding model is not installed:"),
        "engine.health.openaiDown": ("OpenAI non è raggiungibile (connessione internet assente?)", "OpenAI is unreachable (no internet connection?)"),
        "engine.health.openaiKey": ("la chiave API OpenAI non è valida o è scaduta", "the OpenAI API key is invalid or expired"),
        "engine.health.appleMissing": ("i modelli linguistici Apple non sono disponibili su questo Mac", "Apple language models are unavailable on this Mac"),
        "engine.health.http": ("il motore risponde con errore HTTP", "the engine responds with HTTP error"),

        // MARK: Interruttore generale AI
        "ai.enabled.card": ("Intelligenza artificiale", "Artificial intelligence"),
        "ai.enabled": ("Abilita l'intelligenza artificiale", "Enable artificial intelligence"),
        "ai.enabledNote": ("Attiva indicizzazione dei contenuti, chat e ricerca per contenuto. Quando è disattivata, FolderBase resta un file manager classico: le icone della chat spariscono e la ricerca funziona solo per nome.", "Enables content indexing, chat and content search. When off, FolderBase stays a classic file manager: chat icons disappear and search works by name only."),

        // MARK: Motore AI (provider embedding)
        "ai.engine.card": ("Motore AI (embedding)", "AI engine (embeddings)"),
        "ai.engine.intro": ("Scegli come vengono calcolati gli embedding per la ricerca semantica. Il motore su questo Mac è gratuito e privato; i motori locale e cloud offrono qualità superiore.", "Choose how embeddings are computed for semantic search. The on-device engine is free and private; the local and cloud engines offer higher quality."),
        "ai.provider.label": ("Motore", "Engine"),
        "ai.provider.apple": ("Su questo Mac (Apple)", "On this Mac (Apple)"),
        "ai.provider.ollama": ("Locale (Ollama)", "Local (Ollama)"),
        "ai.provider.openai": ("Cloud (OpenAI · BYOK)", "Cloud (OpenAI · BYOK)"),
        "ai.ollama.url": ("URL di Ollama", "Ollama URL"),
        "ai.ollama.model": ("Modello di embedding", "Embedding model"),
        "ai.openai.model": ("Modello di embedding", "Embedding model"),
        "ai.openai.key": ("Chiave API OpenAI", "OpenAI API key"),
        "ai.openai.saveKey": ("Salva chiave", "Save key"),
        "ai.openai.keySet": ("Chiave configurata", "Key configured"),
        "ai.openai.removeKey": ("Rimuovi", "Remove"),
        "ai.cloudWarning": ("Con il motore cloud il contenuto dei file viene inviato ai server OpenAI.", "With the cloud engine, file content is sent to OpenAI's servers."),
        "ai.test": ("Prova motore", "Test engine"),
        "ai.test.ok": ("OK · dimensione vettore", "OK · vector size"),
        "ai.test.fail": ("Nessuna risposta dal motore. Verifica configurazione/rete.", "No response from the engine. Check configuration/network."),
        "ai.reindexNote": ("Se cambi motore, reindicizza le cartelle: i vettori di motori diversi non sono compatibili.", "If you change engine, re-index your folders: vectors from different engines are not compatible."),

        // MARK: Chat (RAG)
        "ai.chat.card": ("Chat con i documenti", "Chat with documents"),
        "ai.chat.intro": ("Scegli il modello che risponde alle domande sui tuoi documenti. Serve un motore locale (Ollama) o cloud (OpenAI); su questo Mac non c'è un modello di chat integrato.", "Choose the model that answers questions about your documents. A local (Ollama) or cloud (OpenAI) engine is required; there is no built-in chat model on this Mac."),
        "ai.chat.card.subtitle": ("Modello per la chat", "Chat model"),
        "ai.chat.provider": ("Motore chat", "Chat engine"),
        "ai.chat.none": ("Disattivata", "Disabled"),
        "ai.chat.model": ("Modello di chat", "Chat model"),
        "ai.chat.ollamaNote": ("Usa l'URL di Ollama configurato sopra. Assicurati che il modello sia scaricato (ollama pull).", "Uses the Ollama URL configured above. Make sure the model is pulled (ollama pull)."),
        "ai.chat.openaiNote": ("Usa la chiave OpenAI configurata sopra. Le domande e gli estratti dei file vengono inviati a OpenAI.", "Uses the OpenAI key configured above. Questions and file excerpts are sent to OpenAI."),
        "ai.chat.sources": ("Fonti per risposta", "Sources per answer"),
        "ai.chat.sourcesNote": ("Quanti frammenti di documento la chat recupera per ogni domanda. Più alto = risposte più complete ma prompt più lungo (attenzione con i modelli piccoli).", "How many document snippets the chat retrieves per question. Higher = more complete answers but a longer prompt (watch out with small models)."),
        "ai.chat.test": ("Prova chat", "Test chat"),
        "ai.chat.testOk": ("OK · risposta:", "OK · reply:"),
        "ai.chat.testFail": ("Nessuna risposta dal modello di chat. Verifica modello/chiave/rete.", "No reply from the chat model. Check model/key/network."),
        "toolbar.chat": ("Chat", "Chat"),
        "toolbar.chatHelp": ("Chatta con i tuoi documenti indicizzati", "Chat with your indexed documents"),
        "chat.title": ("Chat con i documenti", "Chat with documents"),
        "chat.new": ("Nuova chat", "New chat"),
        "chat.intro": ("Fai una domanda sui tuoi documenti indicizzati. Le risposte si basano sui contenuti trovati e citano le fonti.", "Ask a question about your indexed documents. Answers are grounded in the retrieved content and cite their sources."),
        "chat.placeholder": ("Scrivi una domanda…", "Type a question…"),
        "chat.sources": ("Fonti", "Sources"),
        "chat.needProvider": ("Configura un motore di chat (Ollama o OpenAI) nella sezione Indicizzazione della Configurazione.", "Configure a chat engine (Ollama or OpenAI) in the Indexing section of Settings."),
        "chat.embedFail": ("Impossibile calcolare l'embedding della domanda.", "Could not compute the question embedding."),
        "chat.noContext": ("Nessun contenuto pertinente trovato. Hai indicizzato le cartelle?", "No relevant content found. Have you indexed your folders?"),
        "chat.streamFail": ("Errore nella comunicazione con il motore di chat. Verifica configurazione/rete.", "Error communicating with the chat engine. Check configuration/network."),
        "chat.contextLabel": ("Contesto", "Context"),
        "chat.questionLabel": ("Domanda", "Question"),
        "chat.clarify.similar": ("Ho trovato più documenti diversi che potrebbero rispondere alla domanda, con pertinenza simile:", "I found several distinct documents that could answer this question, with similar relevance:"),
        "chat.clarify.versions": ("Ho trovato più versioni dello stesso documento, con indizi di aggiornamento contrastanti:", "I found multiple versions of the same document, with conflicting freshness signals:"),
        "chat.clarify.question": ("Quale devo usare? Rispondi con il numero, il nome del file, oppure con «tutti» o «il più recente».", "Which one should I use? Reply with the number, the file name, or with “all” / “the most recent”."),
        "chat.source.updated": ("aggiornato al", "updated on"),
        "chat.note.newerUsed": ("Nota sulle fonti: «{old}» sembra una versione precedente di «{new}»; privilegia la versione più recente e segnala eventuali differenze.", "Source note: “{old}” appears to be an older version of “{new}”; favor the most recent version and point out any differences."),
        "chat.rerun": ("Rilancia l'ultima domanda", "Re-run last question"),
        "chat.copy": ("Copia conversazione", "Copy conversation"),
        "chat.export": ("Esporta conversazione (Markdown)", "Export conversation (Markdown)"),
        "chat.export.you": ("Tu", "You"),
        "chat.export.assistant": ("Assistente", "Assistant"),
        "chat.scope.label": ("Ambito", "Scope"),
        "chat.scope.pick": ("Scegli l'ambito della chat", "Choose the chat scope"),
        "chat.scope.all": ("Tutto l'indice", "Entire index"),
        "chat.scope.folder": ("Cartella", "Folder"),
        "chat.scope.file": ("File", "File"),
        "chat.msg.copy": ("Copia messaggio", "Copy message"),
        "chat.msg.rerun": ("Rilancia questa domanda", "Re-ask this question"),
        "chat.msg.regenerate": ("Rigenera risposta", "Regenerate answer"),
        "chat.provider.pick": ("Motore di chat", "Chat engine"),
        "chat.provider.appleUnavailable": ("Su questo Mac (Apple): non disponibile per la chat", "On this Mac (Apple): not available for chat"),
        "settings.backup.subtitle": ("Backup e ripristino del database", "Database backup and restore"),
        "settings.help.subtitle": ("Guida all'uso di FolderBase", "FolderBase user guide"),
        "settings.support.subtitle": ("Versione, informazioni e supporto", "Version, information and support"),

        // MARK: Aiuto
        "help.card": ("Guida all'uso", "User guide"),
        "help.intro": ("Apri la guida completa di FolderBase nel tuo browser. La pagina viene mostrata nella lingua attualmente selezionata.", "Open the full FolderBase guide in your browser. The page is shown in the currently selected language."),
        "help.open": ("Apri la guida nel browser", "Open the guide in the browser"),
        "help.note": ("La guida si apre come pagina web nel browser predefinito del sistema.", "The guide opens as a web page in your system's default browser."),

        // MARK: Lingua
        "language.card": ("Lingua dell'interfaccia", "Interface language"),
        "language.label": ("Lingua", "Language"),
        "language.note": ("Scegli la lingua dei menù e dei pannelli. La modifica è immediata.", "Choose the language of menus and panels. The change is applied immediately."),

        // MARK: Visualizzazione
        "display.card": ("Opzioni tabella", "Table options"),
        "display.showHidden": ("Visualizza file nascosti", "Show hidden files"),
        "display.showHiddenNote": ("Mostra nella tabella i file e le cartelle nascosti (quelli che iniziano con un punto).", "Show hidden files and folders (those starting with a dot) in the table."),
        "display.showExtensions": ("Visualizza estensione dei file", "Show file extensions"),
        "display.showExtensionsNote": ("Mostra l'estensione nel nome dei file. Quando è attiva, rinominando un file puoi modificarne anche l'estensione.", "Show the extension in file names. When on, renaming a file also lets you change its extension."),

        // MARK: Cartelle (pannello)
        "folders.currentCard": ("Cartella corrente", "Current folder"),
        "folders.none": ("Nessuna cartella selezionata", "No folder selected"),
        "folders.addFolder": ("Aggiungi cartella", "Add folder"),
        "folders.createCard": ("Crea nella cartella corrente", "Create in current folder"),
        "folders.extension": ("Estensione", "Extension"),
        "folders.createFolder": ("Crea cartella", "Create folder"),
        "folders.createFile": ("Crea file", "Create file"),
        "folders.createdPrefix": ("Creato:", "Created:"),
        "folders.createFailed": ("Creazione non riuscita.", "Creation failed."),
        "folders.recentCard": ("Cartelle recenti", "Recent folders"),
        "newItem.file": ("File vuoto", "Empty file"),
        "newItem.directory": ("Cartella", "Folder"),
        "newItem.fileTitle": ("Nuovo file", "New file"),
        "newItem.directoryTitle": ("Nuova cartella", "New folder"),

        // MARK: Manutenzione
        "maint.intro": ("Riallinea i metadata al filesystem se hai spostato, rinominato o cancellato file da un'altra parte del Mac.", "Realign metadata with the filesystem if you moved, renamed or deleted files elsewhere on the Mac."),
        "maint.repair": ("Verifica e ripara", "Check and repair"),
        "maint.repairCard": ("Riallineamento metadata", "Metadata realignment"),
        "maint.updated": ("Aggiornati", "Updated"),
        "maint.orphans": ("orfani", "orphans"),
        "maint.removedPrefix": ("Rimossi", "Removed"),
        "maint.orphanMetadataSuffix": ("metadata orfani", "orphan metadata"),
        "maint.removePrefix": ("Rimuovi", "Remove"),
        "maint.autoToggle": ("Rimuovi automaticamente i metadata orfani all'avvio", "Automatically remove orphan metadata at launch"),
        "maint.autoNote": ("Un metadata è “orfano” quando il file a cui era associato non è più raggiungibile (cancellato o spostato su un volume non disponibile).", "A metadata entry is “orphan” when the file it was attached to is no longer reachable (deleted or moved to an unavailable volume)."),
        "maint.autoCard": ("Pulizia automatica", "Automatic cleanup"),

        // MARK: Backup
        "backup.intro": ("FolderBase salva i metadata (colonne e valori) in un database SQLite. Da qui puoi farne un backup, pianificare backup automatici e ripristinare uno stato precedente.", "FolderBase stores metadata (columns and values) in a SQLite database. Here you can back it up, schedule automatic backups and restore a previous state."),
        "backup.manualCard": ("Backup su richiesta", "On-demand backup"),
        "backup.destinationLabel": ("Cartella di destinazione", "Destination folder"),
        "backup.noDestination": ("Nessuna cartella scelta", "No folder chosen"),
        "backup.chooseFolder": ("Scegli cartella…", "Choose folder…"),
        "backup.runNow": ("Esegui backup ora", "Back up now"),
        "backup.lastPrefix": ("Ultimo backup:", "Last backup:"),
        "backup.never": ("mai", "never"),
        "backup.donePrefix": ("Backup creato:", "Backup created:"),
        "backup.autoCard": ("Backup automatico", "Automatic backup"),
        "backup.autoToggle": ("Esegui backup automatici", "Run automatic backups"),
        "backup.intervalLabel": ("Ogni", "Every"),
        "backup.hoursSuffix": ("ore", "hours"),
        "backup.keepLabel": ("Backup da mantenere", "Backups to keep"),
        "backup.autoNote": ("I backup automatici vengono salvati nella cartella di destinazione con data e ora nel nome. Oltre il numero da mantenere, i più vecchi vengono eliminati.", "Automatic backups are saved to the destination folder with date and time in the name. Beyond the number to keep, the oldest ones are deleted."),
        "backup.restoreCard": ("Ripristino", "Restore"),
        "backup.restoreIntro": ("Sostituisci il database attuale con quello di un file di backup. Prima del ripristino viene salvata automaticamente una copia di sicurezza del database corrente.", "Replace the current database with one from a backup file. Before restoring, a safety copy of the current database is automatically saved."),
        "backup.restoreButton": ("Ripristina da file…", "Restore from file…"),
        "backup.restore.confirmTitle": ("Confermi il ripristino?", "Confirm restore?"),
        "backup.restore.confirmButton": ("Ripristina", "Restore"),
        "backup.restore.confirmMessage": ("Il database attuale verrà sostituito con quello selezionato. Una copia di sicurezza dello stato corrente viene salvata automaticamente. Continuare?", "The current database will be replaced with the selected one. A safety copy of the current state is saved automatically. Continue?"),
        "backup.restore.done": ("Ripristino completato.", "Restore completed."),
        "backup.errorPrefix": ("Errore:", "Error:"),
        "backup.error.notReady": ("Database non pronto.", "Database not ready."),
        "backup.error.noDestination": ("Scegli prima una cartella di destinazione.", "Choose a destination folder first."),
        "backup.error.destinationMissing": ("La cartella di destinazione non esiste più.", "The destination folder no longer exists."),
        "backup.panel.chooseFolderPrompt": ("Scegli", "Choose"),
        "backup.panel.restorePrompt": ("Ripristina", "Restore"),

        // MARK: Aspetto
        "appearance.system": ("Automatico", "Automatic"),
        "appearance.light": ("Chiaro", "Light"),
        "appearance.dark": ("Scuro", "Dark"),
        "appearance.themeCard": ("Tema", "Theme"),
        "appearance.themeNote": ("Segui il sistema oppure forza chiaro/scuro.", "Follow the system or force light/dark."),
        "appearance.accentCard": ("Accento", "Accent"),
        "appearance.accentNote": ("Colore usato per le barre di selezione e i controlli dell'app.", "Color used for selection bars and app controls."),
        "appearance.accentCustom": ("Colore personalizzato", "Custom color"),
        "appearance.accentCustomActive": ("Attivo", "Active"),
        "appearance.sidebar": ("Sidebar", "Sidebar"),
        "appearance.table": ("Tabella", "Table"),
        "appearance.resetDefault": ("Ripristina default", "Reset to default"),
        "appearance.fontCard": ("Dimensione caratteri", "Font size"),

        // MARK: Template (pannello)
        "templates.emptyNote": ("Nessun template. Un template definisce un insieme di colonne (nome e tipo) da applicare con un clic a una cartella nuova.", "No templates. A template defines a set of columns (name and type) you can apply to a new folder with one click."),
        "templates.editTemplate": ("Modifica template", "Edit template"),
        "templates.deleteTemplate": ("Elimina template", "Delete template"),
        "templates.newTemplate": ("Nuovo template", "New template"),
        "templates.card": ("Template", "Templates"),
        "templates.footerNote": ("Quando apri una cartella senza colonne FolderBase, usa il pulsante con l'icona dei template in alto a sinistra per generarle automaticamente da un template.", "When you open a folder without FolderBase columns, use the template button at the top left to generate them automatically from a template."),
        "templates.active": ("Template globale", "Global template"),
        "templates.noneActive": ("Nessun template", "No template"),
        "templates.globalCard": ("Template usato da FolderBase", "Template used by FolderBase"),
        "templates.activeNote": ("Un solo template viene applicato a tutte le cartelle gestite e alle loro sottocartelle. Cambiandolo, colonne e opzioni compatibili vengono riallineate senza eliminare i dati esistenti.", "One template is applied to every managed folder and its subfolders. Changing it realigns compatible columns and options without deleting existing data."),
        "templates.cleanupCard": ("Bonifica database SQLite", "Clean up SQLite database"),
        "templates.cleanup": ("Ricollega e bonifica", "Relink and clean up"),
        "templates.cleanupNote": ("Ritrova file e cartelle spostati, ricollega i metadata alla loro identità corrente e rimuove i metadata realmente orfani.", "Finds moved files and folders, reconnects metadata to their current identity, and removes truly orphaned metadata."),
        "templates.noColumns": ("Nessuna colonna", "No columns"),

        // MARK: Info / supporto
        "about.info": ("Informazioni", "Information"),
        "about.tagline": ("File manager metadata-first per macOS.", "Metadata-first file manager for macOS."),
        "about.versionPrefix": ("Versione", "Version"),
        "about.devVersion": ("Versione di sviluppo", "Development build"),
        "about.supportText": ("Se FolderBase ti è utile, puoi offrirmi un caffè su Ko-fi. Grazie!", "If FolderBase is useful to you, you can buy me a coffee on Ko-fi. Thanks!"),
        "about.supportCard": ("Sostieni lo sviluppo", "Support development"),

        // MARK: Aggiornamenti
        "update.card": ("Aggiornamenti", "Updates"),
        "update.check": ("Verifica aggiornamenti", "Check for updates"),
        "update.upToDatePrefix": ("Hai già l'ultima versione:", "You already have the latest version:"),
        "update.availablePrefix": ("Nuova versione disponibile:", "New version available:"),
        "update.failedPrefix": ("Controllo non riuscito:", "Check failed:"),
        "update.download": ("Scarica", "Download"),
        "update.later": ("Più tardi", "Later"),
        "update.autoToggle": ("Verifica automaticamente all'avvio", "Check automatically at launch"),
        "update.autoNote": ("All'avvio, FolderBase controlla su GitHub se è disponibile una versione più recente da scaricare.", "At launch, FolderBase checks GitHub for a newer version available to download."),
        "update.available.title": ("Aggiornamento disponibile", "Update available"),
        "update.available.messagePrefix": ("È disponibile la versione", "Version"),
        "update.available.messageSuffix": ("di FolderBase. Vuoi scaricarla?", "of FolderBase is available. Do you want to download it?"),

        // MARK: Tabella file — empty / navigazione
        "table.chooseFolder": ("Scegli una cartella", "Choose a folder"),
        "table.chooseFolderHint": ("Apri Configurazione nella sidebar e aggiungi una cartella.", "Open Settings in the sidebar and add a folder."),
        "table.noKanban": ("Nessuna colonna Kanban", "No Kanban column"),
        "table.noKanbanHint": ("Aggiungi una colonna di tipo Kanban per usare la vista a board.", "Add a Kanban column to use the board view."),
        "nav.back": ("Indietro", "Back"),
        "nav.forward": ("Avanti", "Forward"),
        "nav.up": ("Cartella superiore", "Parent folder"),
        "table.search": ("Cerca", "Search"),
        "search.scope.name": ("Nome", "Name"),
        "search.scope.content": ("Contenuto (AI)", "Content (AI)"),
        "search.scope.help": ("Cerca per nome file, oppure per contenuto: ricerca ibrida che unisce parole esatte e significato (AI)", "Search by file name, or by content: hybrid search combining exact words and meaning (AI)"),
        "search.subfolders": ("Cerca anche nelle sottocartelle", "Search subfolders too"),

        // MARK: Indicizzazione contenuti (AI / ricerca)
        "toolbar.index": ("Indicizza contenuti", "Index contents"),
        "toolbar.indexHelp": ("Estrae il testo dei file di questa cartella (con OCR per PDF scansionati e immagini) per poterli cercare per contenuto", "Extracts the text of this folder's files (with OCR for scanned PDFs and images) so you can search them by content"),
        "index.running": ("Indicizzazione…", "Indexing…"),
        "index.stop": ("Interrompi", "Stop"),

        // MARK: Toolbar tabella
        "toolbar.selectedSuffix": ("selez.", "selected"),
        "toolbar.edit": ("Modifica", "Edit"),
        "toolbar.editHelp": ("Imposta un valore metadata sugli elementi selezionati", "Set a metadata value on the selected items"),
        "toolbar.trash": ("Cestina", "Trash"),
        "toolbar.trashHelp": ("Sposta nel Cestino gli elementi selezionati", "Move the selected items to the Trash"),
        "delete.confirm.title": ("Conferma eliminazione", "Confirm deletion"),
        "delete.confirm.button": ("Conferma", "Confirm"),
        "delete.confirm.messageOne": ("Vuoi spostare nel Cestino l’elemento selezionato?", "Move the selected item to the Trash?"),
        "delete.confirm.messageManyPrefix": ("Vuoi spostare nel Cestino i", "Move the selected"),
        "delete.confirm.messageManySuffix": ("elementi selezionati?", "items to the Trash?"),
        "toolbar.view": ("Vista", "View"),
        "toolbar.viewHelp": ("Tabella o board Kanban", "Table or Kanban board"),
        "toolbar.columns": ("Colonne", "Columns"),
        "toolbar.columnsHelp": ("Mostra, nascondi o gestisci le colonne", "Show, hide or manage columns"),
        "toolbar.showAllColumns": ("Mostra tutte le colonne", "Show all columns"),
        "toolbar.defaultOrder": ("Ordine predefinito", "Default order"),
        "toolbar.defaultOrderHelp": ("Ripristina ordine predefinito", "Reset to default order"),
        "toolbar.column": ("Colonna", "Column"),
        "toolbar.addColumn": ("Aggiungi colonna", "Add column"),
        "toolbar.addColumnHelp": ("Aggiungi colonna metadata", "Add metadata column"),
        "toolbar.exportCSV": ("Esporta CSV", "Export CSV"),
        "toolbar.exportCSVHelp": ("Esporta la tabella in CSV", "Export the table to CSV"),
        "toolbar.newFile": ("Nuovo file", "New file"),
        "toolbar.newFileHelp": ("Crea un nuovo file nella cartella corrente", "Create a new file in the current folder"),
        "toolbar.newFolder": ("Nuova cartella", "New folder"),
        "toolbar.newFolderHelp": ("Crea una nuova cartella nella cartella corrente", "Create a new folder in the current folder"),

        // MARK: Menù colonne
        "column.nameAlwaysVisible": ("Nome (sempre visibile)", "Name (always visible)"),
        "column.show": ("Mostra colonna", "Show column"),
        "column.hide": ("Nascondi colonna", "Hide column"),
        "column.edit": ("Modifica…", "Edit…"),
        "column.delete": ("Elimina colonna", "Delete column"),

        // MARK: Menù template (toolbar)
        "templateMenu.empty": ("Nessun template — creane uno in Configurazione", "No templates — create one in Settings"),
        "templateMenu.apply": ("Applica template", "Apply template"),
        "templateMenu.columnsWord": ("colonne", "columns"),
        "templateMenu.help": ("Applica un template a questa cartella e alle sue sottocartelle", "Apply a template to this folder and its subfolders"),

        // MARK: Menù contestuale righe
        "ctx.open": ("Apri", "Open"),
        "ctx.quickLook": ("Anteprima rapida", "Quick Look"),
        "ctx.revealFinder": ("Mostra nel Finder", "Reveal in Finder"),
        "ctx.openNewWindow": ("Apri come radice in una nuova finestra", "Open as Root in New Window"),
        "ctx.copyMarkdownLink": ("Copia link Markdown", "Copy Markdown Link"),
        "ctx.chatFile": ("Chatta con questo file", "Chat with this file"),
        "ctx.chatFolder": ("Chatta con questa cartella", "Chat with this folder"),
        "ctx.findSimilar": ("Trova simili a questo", "Find similar to this"),
        "similar.chip": ("Simili a", "Similar to"),
        "ctx.copy": ("Copia", "Copy"),
        "ctx.rename": ("Rinomina", "Rename"),
        "ctx.move": ("Sposta…", "Move…"),
        "ctx.setMetadata": ("Imposta metadata…", "Set metadata…"),
        "ctx.setMetadataManyPrefix": ("Imposta metadata su", "Set metadata on"),
        "ctx.setMetadataManySuffix": ("elementi…", "items…"),
        "ctx.trash": ("Sposta nel Cestino", "Move to Trash"),

        // MARK: Cella nome / link
        "name.helpFolder": ("Doppio clic per aprire la cartella · Invio per rinominare", "Double-click to open the folder · Return to rename"),
        "name.helpFile": ("Doppio clic per aprire con l'app predefinita · Invio per rinominare", "Double-click to open with the default app · Return to rename"),
        "name.dragHint": ("Trascina l'icona per spostare il file", "Drag the icon to move the file"),
        "link.placeholder": ("Percorso o URL", "Path or URL"),
        "link.chooseFile": ("Scegli file o cartella", "Choose file or folder"),
        "link.wiki": ("Collega nota come wiki link", "Link note as wiki link"),
        "link.open": ("Apri link", "Open link"),
        "date.remove": ("Rimuovi data", "Remove date"),

        // MARK: Export CSV intestazioni
        "csv.name": ("Nome", "Name"),
        "csv.size": ("Dimensioni", "Size"),
        "csv.type": ("Tipo", "Type"),
        "csv.created": ("Creato", "Created"),

        // MARK: Colonne standard tabella
        "col.name": ("Nome", "Name"),
        "col.size": ("Dimensioni", "Size"),
        "col.type": ("Tipo", "Type"),
        "col.created": ("Creato", "Created"),

        // MARK: Modifica in blocco
        "bulk.title": ("Imposta metadata sulla selezione", "Set metadata on selection"),
        "bulk.column": ("Colonna", "Column"),
        "bulk.numberValue": ("Valore numerico", "Numeric value"),

        // MARK: Editor colonna / campo
        "field.new": ("Nuova colonna", "New column"),
        "field.edit": ("Modifica colonna", "Edit column"),
        "field.nameColumn": ("Nome colonna", "Column name"),
        "field.values": ("Valori", "Values"),
        "field.newState": ("Nuovo stato", "New state"),
        "field.stateName": ("Nome stato", "State name"),
        "field.noState": ("Nessuno stato definito", "No state defined"),

        // MARK: Editor template
        "templateEditor.new": ("Nuovo template", "New template"),
        "templateEditor.edit": ("Modifica template", "Edit template"),
        "templateEditor.nameTemplate": ("Nome template", "Template name"),
        "templateEditor.noFields": ("Nessun campo. Aggiungi le colonne che questo template deve generare.", "No fields. Add the columns this template should generate."),
        "templateEditor.editField": ("Modifica campo", "Edit field"),
        "templateEditor.removeField": ("Rimuovi campo", "Remove field"),
        "templateEditor.addField": ("Aggiungi campo", "Add field"),
        "templateEditor.fields": ("Campi", "Fields"),
        "templateEditor.newField": ("Nuovo campo", "New field"),

        // MARK: Tipi di campo metadata
        "kind.text": ("Nota libera", "Free text"),
        "kind.number": ("Numero", "Number"),
        "kind.date": ("Data", "Date"),
        "kind.kanban": ("Kanban", "Kanban"),
        "kind.select": ("Select", "Select"),
        "kind.link": ("Link", "Link"),

        // MARK: Colori tag
        "tagColor.gray": ("Grigio", "Gray"),
        "tagColor.red": ("Rosso", "Red"),
        "tagColor.orange": ("Arancio", "Orange"),
        "tagColor.yellow": ("Giallo", "Yellow"),
        "tagColor.green": ("Verde", "Green"),
        "tagColor.blue": ("Blu", "Blue"),
        "tagColor.purple": ("Viola", "Purple"),
        "tagColor.pink": ("Rosa", "Pink"),

        // MARK: Kanban board
        "kanban.unassigned": ("Senza stato", "No state"),

        // MARK: Pannelli di sistema (NSOpenPanel/NSSavePanel)
        "panel.choose": ("Scegli", "Choose"),
        "panel.move": ("Sposta", "Move"),
        "collision.title": ("Un elemento con questo nome esiste già", "An item with this name already exists"),
        "collision.message": ("Scegli se sostituire l’elemento esistente oppure mantenere entrambi creando una copia con un nuovo nome.", "Choose whether to replace the existing item or keep both by creating a copy with a new name."),
        "collision.replace": ("Sostituisci", "Replace"),
        "collision.keepBoth": ("Mantieni entrambi", "Keep Both"),
        "collision.copySuffix": ("copia", "copy"),
        "panel.link": ("Collega", "Link"),
        "panel.linkNote": ("Collega nota", "Link note"),

        // MARK: Errori
        "error.invalidName": ("Nome non valido o elemento già esistente.", "Invalid name or item already exists."),
        "error.cannotCreateFile": ("Impossibile creare il file.", "Could not create the file."),

        // MARK: Valori file
        "file.folderType": ("Cartella", "Folder"),
    ]
}
