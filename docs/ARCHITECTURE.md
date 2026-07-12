# Architecture Overview

FolderBase is a native macOS application built with Swift and SwiftUI.

## Design principles

- **Filesystem first:** original documents remain in their existing locations.
- **Metadata separation:** custom metadata is stored separately from the files.
- **Local first:** core organization and storage operate locally.
- **Optional AI:** indexing, embeddings and document chat can be disabled.
- **Provider transparency:** local and cloud providers are explicitly selected.

## Main components

### User interface

SwiftUI provides the main application interface, with AppKit integration where macOS-specific behaviour is required.

### Filesystem integration

FileManager and macOS filesystem services are used to inspect and operate on real folders. FSEvents supports change detection. Metadata identity is designed to survive supported rename and move operations.

Folder navigation uses a shared LRU `DirectorySnapshotCache`. The table and directory tree reuse the same snapshots, Back/Forward can render cached content immediately, and FSEvents watches only user-selected roots while invalidating affected branches.

### Database

SQLite stores custom metadata, application state, content indexes and embeddings. FTS5 supports full-text search.

Column definitions are owned by folders and resolved hierarchically from the selected root to the current directory. Parent definitions take precedence over same-name child definitions; ordering and visibility follow the same inheritance boundary.

### Document processing

Document text is extracted for indexing. Vision provides OCR for supported scanned documents and images.

### AI providers

FolderBase can use Apple on-device embeddings, Ollama or OpenAI depending on user configuration. Cloud transmission occurs only when a cloud provider is selected.

### Credentials

Provider credentials such as the OpenAI API key are stored in macOS Keychain.

## Sensitive areas for contributors

Changes involving file moves, deletion, database migrations, backups, indexing or credentials require careful review and tests. Original documents must never be altered implicitly.
