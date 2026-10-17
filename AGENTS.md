# Инструкция для ИИ-агентов: установка Inkling и правила работы с репозиторием

Для агентов (Claude Code, Codex и др.), которые ставят приложение пользователю или меняют код. Человеку проще читать
[`docs/INSTALL.md`](docs/INSTALL.md). Правила проекта и принятые решения: [`CLAUDE.md`](CLAUDE.md), [`SPEC.md`](SPEC.md) (раздел 13 главнее остальных).

## Жёсткие запреты

- **Не вводи учётные данные.** Вход в `claude`, `codex`, GitHub делает сам пользователь (`claude`, `codex login`, `gh auth login`).
  Не проси у пользователя токены и ключи, не записывай их в файлы и вывод.
- **Не коммить данные пользователя:** `TestData/real/`, `~/Documents/Inkling/`, фото конспектов, `docs/cli-experiments/tmp/`.
- **Не снимай карантин и не обходи Gatekeeper молча.** Команду `xattr -dr com.apple.quarantine` выполняй только после явного согласия пользователя и только для `/Applications/Inkling.app`.
- Не запускай живые тесты (`TEST_RUNNER_INKLING_LIVE_*`) без просьбы: они тратят лимит подписки и память (Ollama ~9 ГБ).

## Часть A. Установка для пользователя

Сценарий идемпотентный: перед каждым шагом проверь условие, потом действуй. Все проверки ниже read-only.

### A0. Предусловия

```bash
sw_vers -productVersion        # нужно 26 или новее
uname -m                       # нужно arm64
command -v claude codex ollama # хотя бы один движок; отсутствие остальных нормально
```

Если macOS старше 26 или процессор не `arm64`, остановись и сообщи пользователю: приложение не запустится.
Если нет ни одного движка, скажи пользователю, как поставить `claude` (Claude Code) или `codex` (`brew install codex`) и войти вручную.

### A1. Способ 1: готовая сборка (по умолчанию)

```bash
gh release view --repo nkkalmyk/inkling --json tagName,assets --jq '{tagName, assets: [.assets[].name]}'
d=$(mktemp -d) && gh release download --repo nkkalmyk/inkling --pattern 'Inkling-*.zip' --dir "$d"
shasum -a 256 "$d"/Inkling-*.zip   # сверь с суммой в описании релиза: gh release view --repo nkkalmyk/inkling --json body --jq .body
ditto -x -k "$d"/Inkling-*.zip "$d/out" && ditto "$d/out/Inkling.app" /Applications/Inkling.app
```

Если сумма не совпала, остановись и не устанавливай. Распаковывай в отдельную пустую папку, не в папку со скриптами.
Репозиторий приватный: если `gh` вернул 404, пользователю нужно выполнить `gh auth login` под аккаунтом с доступом.

### A2. Способ 2: сборка из исходников

Нужны Xcode и XcodeGen (`brew install xcodegen`).

```bash
gh repo clone nkkalmyk/inkling && cd inkling
xcodegen generate
xcodebuild -scheme Inkling -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData build
ditto build/DerivedData/Build/Products/Release/Inkling.app /Applications/Inkling.app
```

Если `xcodebuild` просит пароль связки ключей для `codesign`, это делает пользователь (кнопка «Разрешить всегда»). Подпись настроена в `project.yml` на Personal Team владельца; у другого человека сборка не подпишется: нужно поменять `DEVELOPMENT_TEAM` на свой (проверено только с командой владельца; вариант с локальной подписью `CODE_SIGN_IDENTITY: "-"` не проверялся).

### A3. Первый запуск и проверка

```bash
codesign -dv /Applications/Inkling.app 2>&1 | head -3   # подпись есть
defaults read /Applications/Inkling.app/Contents/Info CFBundleShortVersionString   # версия совпадает с релизом
open /Applications/Inkling.app
```

Если macOS блокирует запуск, объясни пользователю: правый щелчок → «Открыть» → «Открыть» (один раз). Дальше пользователь сам:
⌘, → «Движок» → «Проверить подключение» (должно быть «Работает»). Результат проверки сообщи в отчёте.

### A4. Запасной движок Ollama (только по просьбе)

Шаги и команды: [`docs/INSTALL.md`](docs/INSTALL.md), раздел «Запасной движок: Ollama». Модель ~7,6 ГБ: предупреди пользователя о месте и памяти до загрузки.

### Что сообщить пользователю в конце

Версию и путь установки, результат проверки подписи, какой движок найден, что осталось сделать вручную (вход в движок, «Открыть» в Gatekeeper).

## Часть B. Правила работы с репозиторием

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

Сборка без предупреждений, все тесты зелёные (сейчас 334). Меняешь поведение — добавь тест. Меняешь интерфейс — следуй
[`docs/design-system.md`](docs/design-system.md) и проверь экран в запущенном приложении, а не только сборкой. Не нашёл способа проверить — напиши об этом в PR.

### Чего не делать в коде

- Флаги внешних CLI (`claude`, `codex`, `ollama`) бери из [`docs/cli-notes.md`](docs/cli-notes.md), не из памяти. Нужен новый флаг — сначала `--help` и пробный запуск, результат запиши в `cli-notes.md`.
- Сторонние зависимости — только JS-ассеты в бандле с зафиксированными версиями (`Inkling/Resources/Web/vendor/VERSIONS.md`). Никаких SPM, CocoaPods, сети во время работы приложения.
- Решения из `SPEC.md` (раздел 13) не пересматривай без вопроса владельцу.
- Интерфейс и сообщения об ошибках на русском, идентификаторы на английском. Никаких `print` и `NSLog` в итоговом коде.
- Пользовательские данные пишутся атомарно (`AtomicFile`), чтение файлов лекций — вне главного потока (файлы в iCloud могут быть выгружены).

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
3. Проверка и сборка:
   ```bash
   xcodegen generate && xcodebuild -scheme Inkling -destination 'platform=macOS' build test
   xcodebuild -scheme Inkling -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData build
   ```
4. Упаковка: `mkdir -p build/release && ditto -c -k --keepParent build/DerivedData/Build/Products/Release/Inkling.app build/release/Inkling-X.Y.Z.zip && shasum -a 256 build/release/Inkling-X.Y.Z.zip`.
5. Релиз: `gh release create vX.Y.Z build/release/Inkling-X.Y.Z.zip --target main --title "Inkling X.Y.Z" --notes-file <файл>`. В заметках: что нового, установка, предупреждение про Gatekeeper, SHA-256, что не проверено.
6. Тег `vX.Y.Z` ставит `gh release create`; уже опубликованные теги не двигай.

### Безопасность репозитория

- Репозиторий приватный. Публикацию (смена видимости) предлагай только после чистки `docs/cli-experiments/raw/` от почты, `session_id` и локальных путей (см. [`docs/PROBLEMS.md`](docs/PROBLEMS.md), SEC-04).
- Секреты не коммитятся никогда; нашёл случайно — сообщи владельцу и не пытайся «замести следы» коммитом поверх.
- Перед коммитом смотри `git status` и `git diff --staged`: в индексе только то, что относится к задаче.
