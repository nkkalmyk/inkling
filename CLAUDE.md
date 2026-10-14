# Inkling (Конспектор)

Нативное macOS-приложение (Swift + SwiftUI, XcodeGen). Полное ТЗ лежит в `SPEC.md`. Уточнения после согласования собраны в разделе 13 и имеют приоритет. Все решения там уже согласованы с владельцем, не пересматривай их без вопроса.

## Как работать
- Работай строго по этапам из `SPEC.md`, раздел 11. Не переходи к следующему этапу, пока текущий не собирается, тесты не зелёные и приложение не запускается.
- Перед кодом нужны этап 0 (разведка CLI, `docs/cli-notes.md`) и утверждённый план.
- Флаги `gemini` и `claude` бери только из `docs/cli-notes.md`, а не из памяти.
- Сборка и тесты из консоли: `xcodegen generate && xcodebuild -scheme Inkling -destination 'platform=macOS' build test`. Если схема называется иначе, обнови эту строку.
- Живые тесты с настоящим `claude` (тратят лимит, по умолчанию выключены): `TEST_RUNNER_INKLING_LIVE_CLAUDE=1 xcodebuild -scheme Inkling -destination 'platform=macOS' test -only-testing:InklingTests/ClaudeLiveTests -only-testing:InklingTests/RecognitionLiveTests -only-testing:InklingTests/AssemblyLiveTests`.
- Сторонние зависимости только в виде JS-ассетов (KaTeX, mhchem, markdown-it) в бандле, с зафиксированными версиями.
- Не коммить пользовательские данные: `TestData/real/`, содержимое `~/Documents/Inkling/`.
- Интерфейс и сообщения об ошибках на русском, идентификаторы в коде на английском.
