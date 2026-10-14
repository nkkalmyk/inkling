# Inkling: сборка и установка

## Что нужно

- Mac на Apple Silicon, macOS 14 или новее.
- Xcode (из App Store) и XcodeGen: `brew install xcodegen`.
- Claude Code с выполненным входом (`claude`, затем вход через подписку Claude Pro).

## Сборка

```
cd ~/study-app-local
xcodegen generate
xcodebuild -scheme Inkling -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData build
```

Готовое приложение: `build/DerivedData/Build/Products/Release/Inkling.app`.

Тесты: `xcodebuild -scheme Inkling -destination 'platform=macOS' test` (живые вызовы Claude по умолчанию выключены, см. `CLAUDE.md`).

## Установка

```
ditto build/DerivedData/Build/Products/Release/Inkling.app /Applications/Inkling.app
open /Applications/Inkling.app
```

Приложение подписано сертификатом Apple Development (Personal Team `XXXXXXXXXX`). Разрешения macOS (доступ к «Документам», Камера непрерывности) сохраняются между пересборками.

При первой сборке macOS может спросить пароль связки ключей для `codesign` — введите пароль учётной записи Mac и нажмите «Разрешить всегда».

## Если ругается Gatekeeper

Собранное на этом Mac приложение обычно запускается сразу. Если появилось «Не удаётся открыть Inkling» (например, приложение скопировано с другого компьютера или скачано):

1. Правый щелчок по `Inkling.app` в «Программах» → «Открыть» → «Открыть». Один раз.
2. Или «Системные настройки» → «Конфиденциальность и безопасность» → внизу «Inkling заблокировано» → «Всё равно открыть».
3. Или в Терминале снять карантин: `xattr -dr com.apple.quarantine /Applications/Inkling.app`.

## Первый запуск

- Данные лежат в `~/Documents/Inkling/` (меняется в настройках, ⌘,). Там же папка `_prompts` с промптами.
- В настройках → «Движок» → «Проверить подключение»: должно показать путь к `claude`, версию и «Работает».
- Если Claude Code установлен в нестандартное место, укажите путь к `claude` вручную там же.

## Запасной движок: Ollama (необязательно)

Локальная модель подменяет Claude, когда закончился лимит подписки, или работает вместо него, если выбрать «Только локальная» в меню «Модель» на панели лекции. Она медленнее (30–70 с на страницу против нескольких секунд) и чаще ошибается на плотном почерке: всё, что она сделала, помечено «проверьте». Подробности — `docs/local-models.md`.

```
brew install ollama
ollama serve &                 # только на время установки модели; дальше сервер запускает Inkling
ollama pull qwen3.5:9b         # ~7,6 ГБ
ollama create inkling-ocr -f docs/ollama/inkling-ocr.Modelfile
kill %1
```

Затем в настройках → «Движок»: «Запасной движок» — «Ollama (локально)», модель `inkling-ocr`, «Проверить подключение». Сервер Ollama приложение запускает само, когда он нужен, и закрывает при выходе (если запускало само). Автозапуск через `brew services` не нужен.
