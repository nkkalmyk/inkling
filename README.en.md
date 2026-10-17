# Inkling

**Photos of handwritten notes in, clean notes and flashcards out.** A native macOS app (Swift, SwiftUI) that recognises handwritten lecture notes and teacher slides (chemistry, maths, physics), assembles them into a tidy Markdown note with formulas, and builds questions, a quiz and flashcards for self-testing. The interface is in Russian.

> Status: v0.5.x. Russian is the primary language of the docs; this page is a short summary.

## Requirements

- Mac with Apple Silicon, macOS 26 or newer.
- One AI engine, already installed and signed in (Inkling has no API keys of its own): [Claude Code](https://claude.com/claude-code) (main), Codex (not tested with a live subscription), or a local [Ollama](https://ollama.com) model (fallback).

## Install

1. Download `Inkling-<version>.zip` from [Releases](https://github.com/nkkalmyk/inkling/releases) and move `Inkling.app` to Applications.
2. The build is ad-hoc signed and **not notarized**. On first launch: right-click → Open → Open, or run `xattr -dr com.apple.quarantine /Applications/Inkling.app`.
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
