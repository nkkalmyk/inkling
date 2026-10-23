# AGENTS.md — инструкция для ИИ-агентов

Для агентов (Claude Code, Codex и др.), которые меняют код Inkling или ставят приложение пользователю. Файл главный:
`CLAUDE.md` только ссылается сюда. Все команды ниже проверены на этой версии репозитория; если команда не работает, скажи об этом, а не подменяй её.

## Что это

**Inkling** — нативное macOS-приложение (Swift 6, SwiftUI, macOS 26+, XcodeGen): фото рукописных конспектов и PDF слайдов → Markdown-конспект с формулами → вопросы, тест, флеш-карточки. Своих API-ключей нет: приложение запускает установленные CLI (`claude`, `codex`) или локальную Ollama. Данные — обычные файлы в `~/Documents/Inkling/`, базы нет.
Полное ТЗ — `SPEC.md`; **раздел 13 главнее остальных**, решения оттуда согласованы с владельцем, не пересматривай их без вопроса.

## Архитектура и ключевые файлы

| Папка | Что внутри |
|---|---|
| `Inkling/App` | `InklingApp`, `AppDelegate`, `AppSettings`, `EngineCenter` (выбор и состояние движков) |
| `Inkling/Engine` | `AIEngine` (протокол), `ClaudeCodeEngine`, `CodexEngine`, `OllamaEngine`, `EngineRouter` (основной → запасной), `ProcessRunner` (`posix_spawn`), `BinaryLocator`, `RateLimitDetector` |
| `Inkling/Pipeline` | `Recognition` (страница → Markdown, режим «Подробно»), `Assembly` (сборка `konspekt.md`: «Учебный конспект» по фото страниц — `StudyAssembly`, «Точная сборка» по тексту), `Study` (вопросы, тест, карточки), `Enrichment` («Дополнить»), `Prompts/PromptLibrary` |
| `Inkling/Literature` | индекс учебников: `LiteratureIndexer` (PDFKit-слой или Vision OCR сканов), `LiteratureStore` (SQLite FTS5 в Application Support), `RussianNormalizer`, `LiteratureRetrieval` (выдержки по словам лекции), `LiteratureCenter` (состояние для UI) |
| `Inkling/Library`, `Inkling/Storage` | состояние библиотеки для UI; файловое хранилище (`AtomicFile`, `LectureMeta`, `KonspektStore`, `HistoryStore`, iCloud) |
| `Inkling/Import`, `Inkling/Processing` | импорт файлов, буфера, Камеры непрерывности; обработка фото и PDF |
| `Inkling/Export` | Markdown, PDF, Anki CSV |
| `Inkling/UI` | экраны: `Sidebar`, `Lecture`, `Sources`, `Notes`, `Study`, `Settings` |
| `Inkling/DesignSystem` | токены (`Tokens/`) и общие компоненты (`Components/`) |
| `Inkling/Resources` | `Prompts/` (промпты), `Web/` (рендер конспекта: KaTeX, mhchem, markdown-it в `vendor/`), `Assets.xcassets`, `Inkling.icon`, `ru.lproj` |
| `InklingTests` | тесты на Swift Testing; живые тесты (`*LiveTests`, `EndToEndTests`) выключены флагами |
| `Config` | `Project.xcconfig` (подпись по умолчанию — ad-hoc), `Signing.example.xcconfig` |
| `scripts` | `release.sh` (публичная сборка), `cli-run.sh` и `make-test-images.swift` (разведка CLI) |

Поток данных: импорт → предобработка → `Recognition` (по странице) → `Assembly` (кнопка «Собрать»; по умолчанию «Учебный конспект»: фото страниц целиком + выдержки из учебников индекса) → `Study` → экспорт. Любой вызов модели идёт через `EngineRouter`.
`project.yml` — источник правды для проекта; `Inkling.xcodeproj` генерируется (`xcodegen generate`) и в git не лежит.

## Команды (проверены)

```bash
brew install xcodegen                                        # один раз
xcodegen generate                                            # после любого изменения project.yml, добавления/удаления файлов
xcodebuild -scheme Inkling -destination 'platform=macOS' build test   # сборка и ~360 тестов, ~1–2 мин
xcodebuild -scheme Inkling -destination 'platform=macOS' analyze      # статический анализ (отдельного линтера нет)
scripts/release.sh                                           # публичный zip в build/release/ (ad-hoc, без личных путей)
```

Линтеров и форматтеров (SwiftLint, swift-format) в проекте нет; сборка идёт без предупреждений — не добавляй их.
Живые тесты (тратят лимит подписки и память, без просьбы не запускай):

```bash
TEST_RUNNER_INKLING_LIVE_CLAUDE=1 xcodebuild -scheme Inkling -destination 'platform=macOS' test \
  -only-testing:InklingTests/ClaudeLiveTests -only-testing:InklingTests/RecognitionLiveTests \
  -only-testing:InklingTests/AssemblyLiveTests -only-testing:InklingTests/StudyLiveTests
TEST_RUNNER_INKLING_LIVE_OLLAMA=1 xcodebuild -scheme Inkling -destination 'platform=macOS' test \
  -only-testing:InklingTests/OllamaLiveTests -only-testing:InklingTests/EndToEndTests   # ~9 ГБ памяти; потом pkill -f "ollama serve"
```

Учебная сборка на копии реальной лекции: `TEST_RUNNER_INKLING_LIVE_CLAUDE=1 TEST_RUNNER_INKLING_LIVE_LECTURE=<папка лекции> TEST_RUNNER_INKLING_LIVE_OUT=<файл> xcodebuild -scheme Inkling -destination 'platform=macOS' test -only-testing:InklingTests/StudyAssemblyLiveTests` (модель — `INKLING_LIVE_MODEL`, по умолчанию opus). Индексация реальных учебников (долго, греет процессор): `TEST_RUNNER_INKLING_LIVE_INDEX=1 TEST_RUNNER_INKLING_LIVE_BOOKS=<файл строк «коллекция|путь к PDF»> TEST_RUNNER_INKLING_LIVE_LOG=<лог> xcodebuild … test -only-testing:InklingTests/LiteratureIndexLiveTests`; пишет в настоящий индекс приложения. Сравнение обычного и подробного распознавания: `INKLING_LIVE_PAGE`, `INKLING_LIVE_OUT_DIR`, `INKLING_LIVE_VARIANTS` (`DetailedRecognitionLiveTests`).

«Дополнить» на реальном конспекте: `TEST_RUNNER_INKLING_LIVE_CLAUDE=1 TEST_RUNNER_INKLING_LIVE_KONSPEKT=<konspekt.md> TEST_RUNNER_INKLING_LIVE_OUT=<файл> xcodebuild … -only-testing:InklingTests/EnrichmentLiveTests` (работает с копией).

## Конвенции кода

- Swift 6 со строгой конкурентностью. Тяжёлое и чтение файлов лекций — вне главного потока (в iCloud файл может быть выгружен). Файлы данных пишутся атомарно (`AtomicFile`).
- Пиши по правилам скилла `write-swift`: value types, `actor`/`@MainActor` по назначению, без `print`/`NSLog`, без принудительных разворачиваний там, где можно обойтись.
- Идентификаторы в коде на английском; интерфейс, сообщения об ошибках, комментарии, коммиты — на русском. Комментарий только там, где неочевидно «почему».
- Сторонний код — только JS-ассеты в бандле с зафиксированными версиями (`Inkling/Resources/Web/vendor/VERSIONS.md`). Никаких SPM/CocoaPods и сетевых вызовов приложения (кроме loopback Ollama).
- Флаги внешних CLI бери только из `docs/cli-notes.md`; нужен новый — сначала `--help` и пробный запуск, результат запиши туда же.
- Новая функция — тест рядом (`InklingTests`). Меняешь интерфейс — запусти приложение и посмотри экран, а не только сборку.

## Что нельзя трогать без вопроса владельцу

- **Секреты и личное:** `Config/Signing.xcconfig`, `TestData/real/`, `~/Documents/Inkling/`. Не коммить, не читай без нужды, не печатай в ответ.
- **Промпты для моделей** (`Inkling/Resources/Prompts/*.md`, `subjects/`) — это поведение продукта: каждая правка меняет результат распознавания и сборки. Правь только по прямой просьбе и сверяй живым тестом; подстановки (`{предмет}`, `{тема}`, `{конспект}` …) не переименовывай.
- Решения из `SPEC.md`, раздел 13; изоляцию вызова `claude` (`--tools Read --safe-mode --restricted …`) и очистку окружения дочерних процессов (`ClaudeCodeEngine.environment`).
- `Inkling/Resources/Web/vendor/` (минифицированные KaTeX, markdown-it) — только обновление с фиксацией версии в `VERSIONS.md`.
- Bundle ID `com.nkalmykov.inkling`: от него зависят разрешения macOS и настройки пользователей.

## Как добавить строку интерфейса

Каталога локализации нет: интерфейс только русский, строки пишутся литералами прямо в SwiftUI (`Text("…")`, `Button("…")`). Правила: без точки в заголовках и кнопках, «ё» не заменяй на «е» в готовом тексте, обращение на «вы» в подсказках, глагол в кнопках («Собрать», «Распознать заново»). `ru.lproj/InfoPlist.strings` содержит только название приложения (`CFBundleDisplayName`, `CFBundleName`); тексты запросов разрешений в проекте не заданы, а добавляешь новый `NS…UsageDescription` — клади его в `project.yml` (`INFOPLIST_KEY_…`). Появится второй язык — перенеси литералы в String Catalog и обнови этот раздел.

## Как добавить компонент дизайн-системы

1. Прочитай `docs/design-system.md` (принципы, токены, чек-лист экрана).
2. Файл в `Inkling/DesignSystem/Components/<Имя>.swift`; значения только из `Tokens/` (`Spacing`, цвета из `Colors.swift`, шрифты из `Typography.swift`), никаких «магических» чисел и своих `glassEffect`.
3. Обязательно `#Preview` в светлой и тёмной теме через `ThemePair` (`DesignSystem/Preview/ThemePair.swift`) и подпись/значок для статуса (не только цвет).
4. Используй компонент на экране вместо локальной вёрстки; добавь описание в `docs/design-system.md` и строку в `CHANGELOG.md`.
5. После `xcodegen generate` проверь сборку и тесты.

## Жёсткие запреты

- **Не вводи учётные данные.** Вход в `claude`, `codex`, GitHub делает сам пользователь (`claude`, `codex login`, `gh auth login`).
  Не проси у пользователя токены и ключи, не записывай их в файлы и вывод.
- **Не коммить данные пользователя:** `TestData/real/`, `~/Documents/Inkling/`, фото конспектов, `docs/cli-experiments/tmp/`.
- **Не снимай карантин и не обходи Gatekeeper молча.** Команду `xattr -dr com.apple.quarantine` выполняй только после явного согласия пользователя и только для `/Applications/Inkling.app`.
- Не запускай живые тесты (`TEST_RUNNER_INKLING_LIVE_*`) без просьбы: они тратят лимит подписки и память (Ollama ~9 ГБ).

## Установка для пользователя (сценарий для агента)

Сценарий идемпотентный: перед каждым шагом проверь условие, потом действуй. Все проверки ниже read-only.

### 0. Предусловия

```bash
sw_vers -productVersion        # нужно 26 или новее
uname -m                       # нужно arm64
command -v claude codex ollama # хотя бы один движок; отсутствие остальных нормально
```

Если macOS старше 26 или процессор не `arm64`, остановись и сообщи пользователю: приложение не запустится.
Если нет ни одного движка, скажи пользователю, как поставить `claude` (Claude Code) или `codex` (`brew install codex`) и войти вручную.

### 1. Способ 1: готовая сборка (по умолчанию)

```bash
gh release view --repo nkkalmyk/inkling --json tagName,assets --jq '{tagName, assets: [.assets[].name]}'
d=$(mktemp -d) && gh release download --repo nkkalmyk/inkling --pattern 'Inkling-*.zip' --dir "$d"
shasum -a 256 "$d"/Inkling-*.zip   # сверь с суммой в описании релиза: gh release view --repo nkkalmyk/inkling --json body --jq .body
ditto -x -k "$d"/Inkling-*.zip "$d/out" && ditto "$d/out/Inkling.app" /Applications/Inkling.app
```

Если сумма не совпала, остановись и не устанавливай. Распаковывай в отдельную пустую папку, не в папку со скриптами.
Репозиторий приватный: если `gh` вернул 404, пользователю нужно выполнить `gh auth login` под аккаунтом с доступом.

### 2. Способ 2: сборка из исходников

Нужны Xcode и XcodeGen (`brew install xcodegen`).

```bash
gh repo clone nkkalmyk/inkling && cd inkling
xcodegen generate
xcodebuild -scheme Inkling -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData build
ditto build/DerivedData/Build/Products/Release/Inkling.app /Applications/Inkling.app
```

Если `xcodebuild` просит пароль связки ключей для `codesign`, это делает пользователь (кнопка «Разрешить всегда»). Без `Config/Signing.xcconfig` сборка подписывается ad-hoc и запускается на любом Mac (проверено). Свою стабильную подпись пользователь добавляет сам: `cp Config/Signing.example.xcconfig Config/Signing.xcconfig` и вписывает свой `DEVELOPMENT_TEAM`.

### 3. Первый запуск и проверка

```bash
codesign -dv /Applications/Inkling.app 2>&1 | head -3   # подпись есть
defaults read /Applications/Inkling.app/Contents/Info CFBundleShortVersionString   # версия совпадает с релизом
open /Applications/Inkling.app
```

Если macOS блокирует запуск, объясни пользователю: двойной щелчок → закрыть окно → «Системные настройки» → «Конфиденциальность и безопасность» → «Всё равно открыть». (Правый щелчок → «Открыть» в macOS 15+ не обходит блокировку.) Терминальный вариант `xattr -dr com.apple.quarantine /Applications/Inkling.app` — только с согласия пользователя.
⌘, → «Движок» → «Проверить подключение» (должно быть «Работает»). Результат проверки сообщи в отчёте.

### 4. Запасной движок Ollama (только по просьбе)

Шаги и команды: [`docs/INSTALL.md`](docs/INSTALL.md), раздел «Запасной движок: Ollama». Модель ~7,6 ГБ: предупреди пользователя о месте и памяти до загрузки.

### Что сообщить пользователю в конце

Версию и путь установки, результат проверки подписи, какой движок найден, что осталось сделать вручную (вход в движок, «Открыть» в Gatekeeper).

## Правила работы с репозиторием

### Ветки и pull request'ы

- `main` всегда собирается и проходит тесты. В `main` напрямую не коммить и не делай force-push. Историю не переписывай (исключение: разовая чистка персональных данных по прямой просьбе владельца).
- Одна задача — одна ветка от свежего `main`: `fix-<что>`, `feature-<что>` или по смыслу (`audit-followups`, `enrich-konspekt`). Названия латиницей, через дефис.
- Слияние через pull request, в стиле истории проекта: merge commit (`gh pr merge N --merge`). Ветку после слияния можно удалить.
- Заголовок и описание PR на русском: что изменено, почему, как проверено, что не проверено. Незаконченное и непроверенное называй прямо (как в PR про Codex: «не проверен вживую»).
- Конфликты решай слиянием `main` в свою ветку, а не переписыванием истории. Не принимай чужую сторону вслепую: читай обе.

### Коммиты

- Сообщение на русском, одной строкой в повелительном или назывном стиле, без точки: «Режим „Подробно“: сетка 3×2 вместо полос». Тело коммита — по необходимости (зачем, а не что).
- Один коммит — одна логическая правка. Не смешивай рефакторинг, фичу и документацию.
- Не коммить сгенерированное: `*.xcodeproj/` (генерируется XcodeGen), `build/`, `DerivedData/`, `.DS_Store`.
- Не коммить временные стенды, например `InklingTests/ScreenHarnessScratch.swift`.

### Перед PR (обязательно)

```bash
xcodegen generate && xcodebuild -scheme Inkling -destination 'platform=macOS' build test
```

Сборка без предупреждений, все тесты зелёные (сейчас около 360). Меняешь поведение — добавь тест. Меняешь интерфейс — следуй
[`docs/design-system.md`](docs/design-system.md) и проверь экран в запущенном приложении, а не только сборкой. Не нашёл способа проверить — напиши об этом в PR.

### Документация идёт вместе с кодом

| Что изменилось | Что обновить |
|---|---|
| Любое видимое пользователю изменение | `CHANGELOG.md` (новая версия сверху, по-русски, что и зачем) |
| Решение, меняющее ТЗ | `SPEC.md`, раздел 13 |
| Работа с CLI-движком | `docs/cli-notes.md` |
| Найденная проблема или ограничение | `docs/PROBLEMS.md` |
| Структура папок, команды, установка | `README.md`, `docs/INSTALL.md`, `CLAUDE.md` |
| Важный этап или решение | `docs/HISTORY.md` |

### Версии и релиз

Версия в формате `MAJOR.MINOR.PATCH`: новая возможность — MINOR, исправление — PATCH. Релиз делает только владелец или по его прямой просьбе.

1. В отдельном коммите подними `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION` (+1) в `project.yml`, бейдж версии в `README.md`, заголовок в `CHANGELOG.md`.
2. Слей PR в `main`, переключись на свежий `main`.
3. Проверка: `xcodegen generate && xcodebuild -scheme Inkling -destination 'platform=macOS' build test`.
4. Сборка и упаковка: `scripts/release.sh` — ad-hoc подпись (без личного сертификата и почты), убираются отладочные пути, проверяется, что в zip нет домашней папки; результат `build/release/Inkling-X.Y.Z.zip` и `.sha256`.
5. Релиз: `gh release create vX.Y.Z build/release/Inkling-X.Y.Z.zip --target main --title "Inkling X.Y.Z" --notes-file <файл>`. В заметках: что нового, установка, шаги «Всё равно открыть» (сборка не нотаризована), SHA-256, что не проверено.
6. Уже опубликованные теги не двигай.

### Безопасность репозитория

- Репозиторий публичный. Перед каждым PR `gitleaks` не должен находить ничего (в CI он запускается сам; локально: `brew install gitleaks && gitleaks dir . --redact`).
- Не пиши в коммитах, issue и PR личную почту, домашние пути, `session_id`, содержимое чужих конспектов. Примеры — только синтетические.
- Секреты не коммитятся никогда; нашёл случайно — сообщи владельцу и не пытайся «замести следы» коммитом поверх.
- Перед коммитом смотри `git status` и `git diff --staged`: в индексе только то, что относится к задаче.
