# Contributing to FolderBase

Thank you for helping improve FolderBase.

## Ways to contribute

- Report reproducible bugs.
- Suggest focused features or usability improvements.
- Improve English or Italian documentation.
- Add or improve automated tests.
- Review accessibility and macOS compatibility.
- Submit code through a pull request.

## Before opening an issue

1. Search existing issues and discussions.
2. Test with the latest release or the current `main` branch when practical.
3. Remove personal document names, paths, API keys and sensitive excerpts from screenshots and logs.

Use the provided issue forms for bug reports and feature requests.

## Development requirements

- macOS 14.4 or later;
- Swift 5.9 or later;
- recent Xcode or Command Line Tools;
- Git.

Clone and build:

```bash
git clone https://github.com/PaoloSturbini/FolderBase.git
cd FolderBase
swift build --build-path /tmp/folderbase-build
swift run --build-path /tmp/folderbase-run FolderBase
```

## Branches and commits

- Create a dedicated branch from `main`.
- Keep each pull request focused on one coherent change.
- Write concise, imperative commit messages, for example: `Add database migration test`.
- Avoid including generated build products, user databases, API keys or local configuration.

## Pull requests

A pull request should include:

- the problem being solved;
- a summary of the implementation;
- testing performed;
- screenshots for interface changes;
- documentation updates where behavior changes;
- any known limitations or migration implications.

Substantial architectural changes should be discussed in an issue before implementation.

## Testing

Run at least:

```bash
swift build --build-path /tmp/folderbase-build
```

When test targets are present, also run:

```bash
swift test --build-path /tmp/folderbase-tests
```

High-priority test areas include database migrations, metadata persistence after rename/move, backup and restore, indexing, full-text search, OCR handling and protection of credentials/log output.

## Coding principles

- Preserve the local-first model.
- Never modify original user documents unless the action is explicitly requested by the user.
- Avoid silently sending document content to cloud services.
- Keep provider selection and data flow understandable to users.
- Prefer small, reviewable changes.
- Follow the existing Swift and SwiftUI conventions in the codebase.

## Security

Do not disclose vulnerabilities in public issues. Follow [SECURITY.md](SECURITY.md).

## Code of conduct

Participation is governed by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
