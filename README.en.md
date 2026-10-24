# Inkling

**Photos of handwritten notes in, clean notes and flashcards out.** A native macOS app (Swift, SwiftUI) that recognises handwritten lecture notes and teacher slides (chemistry, maths, physics), assembles them into a tidy Markdown note with formulas, and builds questions, a quiz and flashcards for self-testing. The interface is in Russian.

> Status: v0.5.x. Russian is the primary language of the docs; this page is a short summary.

## Requirements

- Mac with Apple Silicon, macOS 26 or newer.
- One AI engine, already installed and signed in (Inkling has no API keys of its own): [Claude Code](https://claude.com/claude-code) (main), Codex (not tested with a live subscription), or a local [Ollama](https://ollama.com) model (fallback).

## Install

1. Download `Inkling-<version>.zip` from [Releases](https://github.com/nkkalmyk/inkling/releases) and move `Inkling.app` to Applications.
2. The build is ad-hoc signed and **not notarized** (notarization needs a paid Apple Developer account), so macOS blocks the first launch. This is expected. Double-click `Inkling.app`, dismiss the warning, then open System Settings → Privacy & Security → scroll down → "Open Anyway" and confirm. Or run once in Terminal: `xattr -dr com.apple.quarantine /Applications/Inkling.app`. The old "right-click → Open" trick no longer works on macOS 15+.
3. Settings (⌘,) → Engine → "Check connection".

Build from source: `brew install xcodegen && xcodegen generate && xcodebuild -scheme Inkling -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData build`. Details (Russian): [`docs/INSTALL.md`](docs/INSTALL.md).

## Where things are

| | |
|---|---|
| [`README.md`](README.md) | full description (Russian) |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) / [`AGENTS.md`](AGENTS.md) | rules for people / for AI agents |
| [`SPEC.md`](SPEC.md), [`docs/`](docs) | specification, design system, audit, history, known problems |
| [`CHANGELOG.md`](CHANGELOG.md) | changes per version |

Your data stays in plain files under `~/Documents/Inkling/`. Nothing is uploaded except what the chosen engine CLI sends to its provider.

## License

[MIT](LICENSE)

**Study note (0.6):** the default assembly lets the model see the page photos whole and write a complete study guide (title, table of contents, numbered sections, worked examples); the old text-only assembly stays as "Exact assembly". In Settings → Textbooks you can add your own PDF textbooks: scans are recognised on-device with Vision, indexed locally (SQLite FTS5), and the best-matching pages are passed to the model as excerpts with a sources list.
