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
        "sidebar.removeFolder": ("Togli cartella", "Remove folder"),
        "sidebar.configuration": ("Configurazione", "Settings"),

        // MARK: Sezioni configurazione
        "settings.folders.title": ("Cartelle", "Folders"),
        "settings.appearance.title": ("Aspetto", "Appearance"),
        "settings.language.title": ("Lingua", "Language"),
        "settings.templates.title": ("Template", "Templates"),
        "settings.maintenance.title": ("Manutenzione", "Maintenance"),
        "settings.help.title": ("Aiuto", "Help"),
        "settings.support.title": ("Info su FolderBase", "About FolderBase"),

        "settings.folders.subtitle": ("Cartelle monitorate, creazione elementi e recenti", "Tracked folders, item creation and recents"),
        "settings.appearance.subtitle": ("Tema e dimensione dei caratteri", "Theme and font size"),
        "settings.language.subtitle": ("Lingua dell'interfaccia", "Interface language"),
        "settings.templates.subtitle": ("Insiemi di colonne riutilizzabili", "Reusable sets of columns"),
        "settings.maintenance.subtitle": ("Sincronizzazione e pulizia dei metadata", "Metadata sync and cleanup"),
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

        // MARK: Aspetto
        "appearance.system": ("Automatico", "Automatic"),
        "appearance.light": ("Chiaro", "Light"),
        "appearance.dark": ("Scuro", "Dark"),
        "appearance.themeCard": ("Tema", "Theme"),
        "appearance.themeNote": ("Segui il sistema oppure forza chiaro/scuro.", "Follow the system or force light/dark."),
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
        "templates.noColumns": ("Nessuna colonna", "No columns"),

        // MARK: Info / supporto
        "about.info": ("Informazioni", "Information"),
        "about.tagline": ("File manager metadata-first per macOS.", "Metadata-first file manager for macOS."),
        "about.versionPrefix": ("Versione", "Version"),
        "about.devVersion": ("Versione di sviluppo", "Development build"),
        "about.supportText": ("Se FolderBase ti è utile, puoi offrirmi un caffè su Ko-fi. Grazie!", "If FolderBase is useful to you, you can buy me a coffee on Ko-fi. Thanks!"),
        "about.supportCard": ("Sostieni lo sviluppo", "Support development"),

        // MARK: Tabella file — empty / navigazione
        "table.chooseFolder": ("Scegli una cartella", "Choose a folder"),
        "table.chooseFolderHint": ("Apri Configurazione nella sidebar e aggiungi una cartella.", "Open Settings in the sidebar and add a folder."),
        "table.noKanban": ("Nessuna colonna Kanban", "No Kanban column"),
        "table.noKanbanHint": ("Aggiungi una colonna di tipo Kanban per usare la vista a board.", "Add a Kanban column to use the board view."),
        "nav.back": ("Indietro", "Back"),
        "nav.forward": ("Avanti", "Forward"),
        "nav.up": ("Cartella superiore", "Parent folder"),
        "table.search": ("Cerca", "Search"),

        // MARK: Toolbar tabella
        "toolbar.selectedSuffix": ("selez.", "selected"),
        "toolbar.edit": ("Modifica", "Edit"),
        "toolbar.editHelp": ("Imposta un valore metadata sugli elementi selezionati", "Set a metadata value on the selected items"),
        "toolbar.trash": ("Cestina", "Trash"),
        "toolbar.trashHelp": ("Sposta nel Cestino gli elementi selezionati", "Move the selected items to the Trash"),
        "toolbar.view": ("Vista", "View"),
        "toolbar.viewHelp": ("Tabella o board Kanban", "Table or Kanban board"),
        "toolbar.columns": ("Colonne", "Columns"),
        "toolbar.columnsHelp": ("Mostra, nascondi o gestisci le colonne", "Show, hide or manage columns"),
        "toolbar.showAllColumns": ("Mostra tutte le colonne", "Show all columns"),
        "toolbar.defaultOrder": ("Ordine predefinito", "Default order"),
        "toolbar.defaultOrderHelp": ("Ripristina ordine predefinito", "Reset to default order"),
        "toolbar.column": ("Colonna", "Column"),
        "toolbar.addColumnHelp": ("Aggiungi colonna metadata", "Add metadata column"),
        "toolbar.exportCSV": ("Esporta CSV", "Export CSV"),
        "toolbar.exportCSVHelp": ("Esporta la tabella in CSV", "Export the table to CSV"),

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
        "templateMenu.help": ("Genera le colonne di questa cartella da un template", "Generate this folder's columns from a template"),

        // MARK: Menù contestuale righe
        "ctx.open": ("Apri", "Open"),
        "ctx.quickLook": ("Anteprima rapida", "Quick Look"),
        "ctx.revealFinder": ("Mostra nel Finder", "Reveal in Finder"),
        "ctx.copy": ("Copia", "Copy"),
        "ctx.rename": ("Rinomina", "Rename"),
        "ctx.move": ("Sposta…", "Move…"),
        "ctx.setMetadata": ("Imposta metadata…", "Set metadata…"),
        "ctx.setMetadataManyPrefix": ("Imposta metadata su", "Set metadata on"),
        "ctx.setMetadataManySuffix": ("elementi…", "items…"),
        "ctx.trash": ("Sposta nel Cestino", "Move to Trash"),

        // MARK: Cella nome / link
        "name.helpFolder": ("Doppio clic per aprire la cartella · clic singolo per rinominare", "Double-click to open the folder · single click to rename"),
        "name.helpFile": ("Doppio clic per aprire con l'app predefinita · clic singolo per rinominare", "Double-click to open with the default app · single click to rename"),
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
        "panel.link": ("Collega", "Link"),
        "panel.linkNote": ("Collega nota", "Link note"),

        // MARK: Errori
        "error.invalidName": ("Nome non valido o elemento già esistente.", "Invalid name or item already exists."),
        "error.cannotCreateFile": ("Impossibile creare il file.", "Could not create the file."),

        // MARK: Valori file
        "file.folderType": ("Cartella", "Folder"),
    ]
}
