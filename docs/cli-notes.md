# Разведка CLI (этап 0)

Дата: 2026-10-14. Mac M5, macOS 27.0.1.
Сырые выводы лежат в `docs/cli-experiments/raw/` (`<метка>.out`, `.err`, `.exit`), полный `--help` — в `docs/cli-experiments/`.
Все запуски шли через `scripts/cli-run.sh`: чистое окружение (`env -i`, только `HOME`, `USER`, `TMPDIR`, `LANG` и минимальный `PATH`, как у GUI-приложения), отдельная временная папка, stdin закрыт.
Тестовые картинки генерирует `scripts/make-test-images.swift` (`TestData/synthetic/`).

## Claude Code (`claude`), версия 2.1.289

### Бинарник
- `~/.local/bin/claude` — симлинк на нативный бинарник `~/.local/share/claude/versions/<версия>` (не node-скрипт). Отдельный `node` в `PATH` не нужен.
- Логин (подписка, OAuth из связки ключей) работает в чистом окружении `env -i` без каких-либо переменных.

### Итоговая команда
```
claude -p "<промпт>" \
  --output-format json \
  --model <алиас или полное имя> \
  --system-prompt "<системный промпт приложения>" \
  --tools Read \
  --safe-mode --restricted --strict-mcp-config --setting-sources= \
  --permission-prompts none \
  --no-session-persistence \
  [--json-schema '<JSON Schema>']
```
- Рабочая папка процесса = временная папка с картинками. Картинку модель читает инструментом `Read` по относительному имени из промпта (`./page.png`). Проверено на PNG, ~16 с на страницу (`claude-sysprompt`, `run.7x2L`).
- Промпт можно передать и через stdin (`echo … | claude -p …` без позиционного аргумента), проверено (`claude-stdin`). Для длинных промптов сборки использовать stdin, чтобы не упираться в длину argv.

- JPEG (как после предобработки, `sips` качество 85) распознаётся так же: страница с пределами, производной, интегралом и рядом — 4.6 с, все формулы в LaTeX верные (`claude-jpeg-math`). Промпт распознавания из ТЗ работает как есть, если в конце указать имя файла (`Изображение: ./page.jpg`), а системный промпт велит читать его инструментом `Read`.

### Изоляция (раздел 2.3 ТЗ)
Проверено вопросом «перечисли доступные CLAUDE.md, инструменты, MCP» (`claude-isol-*`):
- без флагов: подхватывается глобальный `~/.claude/CLAUDE.md` и все инструменты (Bash, Edit, Agent…) — так нельзя;
- `--setting-sources=`, `--safe-mode` и `--restricted` по отдельности убирают CLAUDE.md, MCP и пользовательские настройки; с `--tools Read` остаётся только `Read`.
- Используем все сразу: `--safe-mode` (выключает CLAUDE.md, скиллы, плагины, хуки, MCP, агентов), `--restricted` (игнорирует user/project/local settings, убирает исполнение кода и **ограничивает файловые инструменты рабочей папкой**), `--strict-mcp-config` без `--mcp-config` (ни одного MCP), `--setting-sources=` (пустой список источников настроек), `--tools Read` (единственный инструмент).
- Проверено: `Read` за пределами рабочей папки отказывает, отказ попадает в `permission_denials` (`claude-outside`).
- `--permission-prompts none`: всё, что потребовало бы подтверждения, автоматически запрещается, процесс не зависает.
- `--no-session-persistence`: сессии не сохраняются на диск.
- `--bare` **не подходит**: в нём OAuth не читается, работает только `ANTHROPIC_API_KEY`.
- `--system-prompt` полностью заменяет системный промпт Claude Code. Работает с `Read`, ответ быстрее и дешевле (`claude-sysprompt`: 7 с против 16 с). Используем свой короткий системный промпт.

### Формат ответа (`--output-format json`)
Один JSON-объект в stdout. Важные поля:
| поле | значение |
|---|---|
| `type` | `"result"` |
| `result` | текст ответа модели |
| `is_error` | `true` при любой ошибке |
| `subtype` | **`"success"` даже при ошибке** (см. ниже), не полагаться на него |
| `api_error_status` | HTTP-код ошибки API (`404` для неизвестной модели, `null` при успехе), ожидаемо `429` при лимите |
| `structured_output` | объект по `--json-schema`, иначе `null` |
| `modelUsage` | словарь `{<полное имя модели>: {...}}` — отсюда берём фактическую модель (например `claude-sonnet-5-5`) |
| `duration_ms`, `num_turns`, `total_cost_usd`, `permission_denials`, `session_id`, `stop_reason`, `terminal_reason` | служебные |

Пример успеха: `docs/cli-experiments/raw/claude-sysprompt.out`.

### Структурированный вывод
Флаг `--json-schema '<схема>'` есть и работает (`claude-schema`): объект лежит в `structured_output`, а в `result` та же строка JSON. На этапе 3 используем его, но валидацию по схеме у себя оставляем (раздел 5 ТЗ).

### Ошибки
| ситуация | exit | stdout | stderr |
|---|---|---|---|
| успех | 0 | JSON, `is_error: false` | пусто |
| неизвестная модель | 1 | JSON, `is_error: true`, `api_error_status: 404`, `result: "There's an issue with the selected model (no-such-model-xyz). It may not exist or you may not have access to it. Run --model to pick a different model."` | `[claude-code:unrecognized_model] {"model":"no-such-model-xyz","query_source":"sdk"}` |
| нет логина (чужой пустой `HOME`) | 1 | JSON, `is_error: true`, `api_error_status: null`, `result: "Not logged in · Please run /login"` | пусто |
| неизвестный флаг | 1 | пусто | `error: unknown option '…'` |

Вывод: ошибка определяется по `exit != 0` или `is_error == true`; текст причины берётся из `result`, а если stdout не JSON — из stderr.

### Лимит подписки
Вызвать лимит специально нельзя. Тексты найдены в строках бинарника 2.1.289 (`strings`), шаблоны для распознавания (регистронезависимо, в `result` и stderr):
- `usage limit reached`, `Usage limit reached`
- `You've hit your … limit` (`You've hit your limit`, `You've hit your fast limit`, `… monthly spend limit`)
- `You've reached your <модель> limit`
- `You're out of extra usage`
- `rate_limit_error`, `rate limited`, `api_error_status: 429`
- время сброса: `resets at <время>` или `resets <время>` (например `resets 3pm`, `resets at 15:00`); формат времени разбирать мягко, при неудаче `resetAt = nil`.
Список держим в одном месте (массив шаблонов) и покрываем тестами; при первом реальном лимите сохранить пример в `docs/cli-experiments/raw/`.

### Модели
`--model` принимает алиасы (`sonnet`, `opus`, `fable`) и полные имена. С `sonnet` фактически отвечает `claude-sonnet-5-5` (видно в `modelUsage`). По умолчанию для распознавания берём `sonnet`.

## Gemini CLI (`gemini`), версия 0.64.0 — не используется

Установлен через `npm install -g @google/gemini-cli` (node 26 из Homebrew). Итог: **с подпиской Google AI Pro не работает**, в v1 не используется.

- Бинарник `/opt/homebrew/bin/gemini` — симлинк на `…/@google/gemini-cli/bundle/gemini.js` с `#!/usr/bin/env node`. Без каталога `node` в `PATH` запуск падает: exit 127, stderr `env: node: No such file or directory` (`gemini-nonode`). Гипотеза ТЗ подтверждена.
- Без выбранного способа входа: exit 41, JSON в **stderr**: `{"session_id":…,"error":{"type":"Error","message":"Please set an Auth method in your ~/.gemini/settings.json or specify one of the following environment variables before running: GEMINI_API_KEY, GOOGLE_GENAI_USE_VERTEXAI, GOOGLE_GENAI_USE_GCA","code":41}}` (`gemini-noauth`).
- После входа через Google: exit 55, stderr `Error authenticating: IneligibleTierError: This client is no longer supported for Gemini Code Assist for individuals. To continue using Gemini, please migrate to the Antigravity suite of products` с `reasonCode: 'UNSUPPORTED_CLIENT'`, `tierId: 'free-tier'` (`gemini-auth-hi`). По [объявлению Google](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/) с 18.06.2026 Gemini CLI не обслуживает Google AI Pro, Ultra и бесплатный тариф; работает только с платным API-ключом или корпоративной лицензией Code Assist.
- **Доверенные папки:** в недоверенной папке headless-запуск не стартует: `Gemini CLI is not running in a trusted directory. To proceed, either use --skip-trust, set the GEMINI_CLI_TRUST_WORKSPACE=true environment variable, or trust this directory in interactive mode.` Ответ на вопрос ТЗ: да, механизм есть и ломает запуск во временной папке; обход — `--skip-trust`.
- Модель выбирается `-m`, вывод `-o json`; формат успешного ответа проверить не удалось (нет доступа).

## Antigravity CLI (`agy`), версия 1.3.5 — недоступен

Замена Gemini CLI от Google. Установлен официальным скриптом `curl -fsSL https://antigravity.google/cli/install.sh | bash` (бинарник Go, `~/.local/bin/agy`, сам обновляется в фоне). Установщик дописывает `~/.local/bin` в `PATH` в `.zshrc`, `.zprofile`, `.bash_profile`, `.profile`.

Итог: **аккаунту отказано по стране** — `Eligibility check failed: Your current account is not eligible for Antigravity, because it is not currently available in your location.` (интерактивно и в headless: exit 1, `{"status":"ERROR","error":"Eligibility check failed: …"}` в stdout, `error: …` в stderr; `agy-hi`). Выход в интернет при этом через NL, то есть проверяется страна аккаунта, а не IP. В v1 не используется.

Что выяснено на будущее (по [документации headless](https://antigravity.google/docs/cli/headless/) и опытам):
- `agy -p "<промпт>" --output-format json [--model <slug>] [--json-schema <схема>] [--print-timeout 5m]`; `agy models` — список моделей.
- JSON: `conversation_id`, `status` (`SUCCESS`/`ERROR`/`CANCELED`/`INTERRUPTED`/…), `response`, `error`, `duration_seconds`, `num_turns`, `usage`, `structured_output` (с `--json-schema`).
- Ответ в stdout, диагностика в stderr; ошибки в stderr с префиксом `error:`.
- Без входа **не завершается сразу**: печатает ссылку `Authentication required. Please visit the URL to log in:` и ждёт 60 с, затем `authentication failed or timed out` (`agy-noauth`). Приложению нужно ловить эту строку в stderr и прерывать запуск.
- Учётные данные в связке ключей macOS, настройки в `~/.gemini/antigravity-cli/settings.json` (там же `trustedWorkspaces`, `permissions.allow`). Чтение и **запись** файлов в рабочей папке разрешены по умолчанию, запретить запись можно только правилами в глобальном settings.json — изоляция хуже, чем у `claude`.
- Флага, отключающего пользовательские плагины и MCP, в `--help` нет.
- Условия Google по использованию входа Antigravity из сторонних приложений не прояснены; это нужно проверить до того, как делать движок.

## Codex CLI (`codex`, вход через ChatGPT), версия 0.163.0

Дата разведки: 2026-10-17. Установлен `brew install codex` (cask, `/opt/homebrew/bin/codex`). **Подписки ChatGPT у автора нет, поэтому живых ответов модели нет**: проверены `--help`, разбор аргументов и поведение без входа (`codex-noauth` в `raw/`). Движок помечен в интерфейсе «не проверен вживую», формат успешного ответа взят из документации OpenAI ([non-interactive mode](https://developers.openai.com/codex/noninteractive)).

### Команда (по `codex exec --help` и проверке разбора аргументов)
```
codex exec --json --skip-git-repo-check --ephemeral \
  --ignore-user-config --ignore-rules -s read-only \
  -C <временная папка> [-m <модель>] [-i <картинка>]... \
  [--output-schema <файл схемы>] -o <файл с последним сообщением>
```
Промпт идёт через **stdin без аргумента `-`** (в `--help`: «if not provided as an argument … instructions are read from stdin»; без входа выводит «Reading prompt from stdin...»). Если передавать `-` после `-i`, он мог бы съесться как имя файла: `-i, --image <FILE>...` принимает несколько значений.
- `--json` — JSONL-события в stdout; `-o/--output-last-message <FILE>` — только последнее сообщение агента в файл; `--output-schema <FILE>` — JSON Schema финального ответа (файл, не строка).
- `-s read-only` — песочница по умолчанию, команды модели ничего не пишут. `--ephemeral` — без файлов сессий. `--skip-git-repo-check` — запуск вне git-репозитория (наша временная папка не репозиторий).
- `--ignore-user-config` не читает `$CODEX_HOME/config.toml` (MCP, профили, модель пользователя), «auth still uses CODEX_HOME» — вход при этом сохраняется. `--ignore-rules` не читает `.rules`.
- Флага для системного промпта нет: системный промпт приложения вставляется в начало промпта.
- Выбор модели `-m`; неизвестное имя не отказывает, а печатает «Model metadata for `<имя>` not found. Defaulting to fallback metadata…». Поэтому модель по умолчанию **не задаём**: набор моделей зависит от тарифа, берётся выбор Codex.
- `codex login status` без входа печатает «Not logged in» и завершается с кодом 1.

### События `--json`
- Без входа (`codex-noauth`): `thread.started` → `turn.started` → серия `{"type":"error","message":"Reconnecting... N/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: …)"}` (повторы **не фатальны сами по себе**) → `item.completed` с `item.type == "error"` («Falling back from WebSockets to HTTPS transport…») → итоговое `error` и `{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized: …"}}`. Код выхода 1, до отказа проходит около 30 с.
- Успех (из документации, не проверено): `item.completed` с `item.type == "agent_message"` и полем `text`, затем `turn.completed`. Текст берём из файла `-o`, а если его нет — из последнего `agent_message`.
- Лимит тарифа (не проверено): ожидается текст вида «You've hit your usage limit…», он совпадает с `RateLimitDetector`.

### Вход и безопасность
- Вход делает сам пользователь: `codex login` (ChatGPT) в терминале; ключи в приложение не вводятся. Токены лежат в `~/.codex/auth.json` (`CODEX_HOME`).
- Из окружения процесса убираются `OPENAI_*`, `CODEX_API_KEY` и прочие секреты (иначе Codex мог бы перейти с подписки на ключ API).

## Anki: `\ce{}` в MathJax

Anki (2.1+, AnkiMobile, AnkiDroid 2.9+) рендерит формулы встроенным MathJax, и [расширение mhchem в него встроено](https://docs.ankiweb.net/manual/math): `\ce{…}` работает без настройки. Разделители только `\(…\)` и `\[…\]`, `$` не поддерживается — значит, конвертация из раздела 8 ТЗ нужна. Отдельная оговорка в инструкции не требуется.

## Итог для реализации (этап 3)

- Единственный движок v1 — `ClaudeCodeEngine` с командой из раздела «Итоговая команда». Длинные промпты передавать через stdin.
- Поиск бинарника: `claude` — нативный Mach-O, обычно `~/.local/bin/claude` (симлинк на `~/.local/share/claude/versions/<версия>`); `node` не нужен. Список мест из ТЗ 2.4 подходит, `~/.local/bin` в нём уже есть.
- Успех: `exit == 0 && is_error == false`. Ошибка: всё остальное; причину брать из `result`, при нечитаемом stdout — из stderr. `subtype` не использовать.
- Классификация: `Not logged in` → `notAuthenticated`; `api_error_status == 404` или `unrecognized_model` в stderr → ошибка модели (показывать как `processFailed` с понятным текстом «модель недоступна»); шаблоны лимита → `rateLimited(resetAt:)`; exit 127 / нет файла → `binaryNotFound`.
- Фактическая модель для `meta.json` — ключ из `modelUsage`.
