CREATE TABLE IF NOT EXISTS folders (
    id TEXT PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS metadata_fields (
    id TEXT PRIMARY KEY,
    folder_id TEXT,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    options_json TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(folder_id) REFERENCES folders(id)
);

CREATE TABLE IF NOT EXISTS metadata_values (
    id TEXT PRIMARY KEY,
    file_path TEXT NOT NULL,
    field_id TEXT NOT NULL,
    value TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(file_path, field_id),
    FOREIGN KEY(field_id) REFERENCES metadata_fields(id)
);
