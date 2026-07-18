# Privacy and Data Flow

FolderBase is designed around local files and opt-in AI functionality.

## Local data

Original files remain in user-selected folders. FolderBase stores metadata, indexes and related application data in a local SQLite database under the user's Library application-support directory.

## AI disabled

When the master AI switch is disabled, FolderBase does not use an AI embedding or chat provider.

## Apple on-device embeddings

When Apple on-device embeddings are selected, embedding computation occurs on the Mac.

## Ollama

When Ollama is selected, text is sent to the Ollama endpoint configured by the user. A local Ollama instance keeps processing on the user's machine; a remotely configured endpoint is not local and should be treated according to its operator's privacy practices.

## OpenAI

When OpenAI is selected, prompts and relevant document excerpts are sent to OpenAI for the requested embedding or chat operation. FolderBase stores the API key in macOS Keychain rather than in plain-text configuration.

Users should not enable a cloud provider for documents they are not authorized to transmit.

## AI source exclusions

Users can exclude individual files or whole folders from AI indexing, content search, similarity search and document chat. FolderBase also offers optional suggestions for hidden and commonly generated directories; suggestions are never applied automatically. Exclusions are enforced at retrieval time as well, so excluded files are not used as sources even if an older copy is still present in the derived AI index.

## Logs and reports

Before sharing logs, screenshots or bug reports, users should remove document names, file paths, personal content, tokens and API keys.

## Security reports

Follow [../SECURITY.md](../SECURITY.md) for private vulnerability reporting.
