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

## whisper.cpp (`whisper-cli`), версия 1.9.5

Дата разведки: 2026-10-20 (этап 0 плана записей, `docs/plan-recordings.md`). Mac M5, 16 ГБ, macOS 27.0.1. Запуски шли через `scripts/cli-run.sh` (чистое окружение), сырые выводы — `docs/cli-experiments/raw/whisper-*`, полный `--help` — `docs/cli-experiments/whisper-help.txt`.
Тестовая лекция — `docs/cli-experiments/lecture-ru.txt`, озвучена `say -v Milena -r 170` (95 с, формулы и термины «вслух»). **Это один синтетический голос без шума.** Числа ниже сравнивают модели между собой, но не говорят, как будет на настоящей записи: проверка на ней остаётся на этап 6. Различия качества в 0,02 WER — шум (один и тот же звук в другом формате давал разброс 0,48–0,54 у tiny).
«WER» здесь считался против текста лекции как он произнесён, а Whisper пишет формулы символами (`x^2`, `sin x`, `ε`), поэтому абсолютные значения завышены; смотреть стоит на разницу между моделями и на число распознанных терминов из 16 заданных.

### Установка и бинарник
- `brew install whisper.cpp` (старое имя `whisper-cpp` переименовано, brew предупреждает) ставит ещё `ggml` 0.27.0, `libomp`, `llama.cpp`, `sdl3`, `sdl2-compat`, всего около 46 МБ. Бинарник `/opt/homebrew/bin/whisper-cli` — симлинк на `../Cellar/whisper.cpp/1.9.5/bin/whisper-cli`; бэкенды (Metal, BLAS, CPU) подгружаются из `Cellar/ggml/…/libexec`. В чистом окружении `env -i` (только `HOME`, `USER`, `TMPDIR`, минимальный `PATH`) запускается без дополнительных переменных. На Intel префикс brew `/usr/local`, это не проверялось.
- В формуле есть и другие программы (`whisper-server`, `whisper-stream`, `whisper-vad-speech-segments`…), нужен только `whisper-cli`.
- **Моделей формула не ставит.** В `share/whisper.cpp` лежат только `for-tests-ggml-tiny.bin` и `jfk.wav`, стандартного каталога моделей нет. Скачивать с `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/<имя>.bin`.
- `whisper-cli --version` → `whisper.cpp version: 1.9.5`, код 0.
- Первый запуск после установки дольше: tiny потратил 8 с при собственных 2 с расшифровки, в stderr строки `ggml_metal_library_compile_all: compiled '…' library in N sec` (компиляция шейдеров Metal). Дальше те же строки показывают `0.00x sec`.

### Вход
- В `--help`: «supported audio formats: flac, mp3, ogg, wav». **m4a и aac не читает:** `error: failed to read audio file …`, код 11 (`whisper-tiny-m4a`). Значит, приложение конвертирует звук само.
- Без ошибок читаются WAV 16 кГц/16 бит/моно, WAV 44,1 кГц стерео, WAV 48 кГц моно, WAV float32 и FLAC (`whisper-tiny-fmt-*`): встроенный декодер miniaudio сам приводит к 16 кГц моно. mp3 и ogg не пробовал, `afconvert` их не кодирует.
- Подаём WAV 16 кГц моно 16 бит: он в 5,5 раза меньше стерео 44,1 кГц (3,1 МБ против 16,9 МБ на 95 с) и не зависит от того, чем встроен декодер. Получается через `afconvert -f WAVE -d LEI16@16000 -c 1` или `AVAssetReader`.
- Хранимый в папке лекции AAC после обратной распаковки качество не ухудшает: на turbo q5_0 WER 0,257 при 32 кбит/с и 0,257 при 16 кбит/с против 0,241 у исходного WAV (1–2 слова). Размер 95-секундного m4a: 403 КБ при 32 кбит/с, 203 КБ при 16 кбит/с.

### Итоговая команда
```
whisper-cli -m <модель> -f <audio.wav> -l ru -np \
  [-pp] [--prompt "<предмет и тема>"] [--vad -vm <ggml-silero-v5.1.2.bin>]
```
- **`-l <код>` обязателен всегда.** Язык по умолчанию `en`, и без флага русская речь **переводится на английский** («Good morning. Today we have a lesson on math and analysis…», `whisper-turbo-default-lang`). `-l auto` определил русский сам и дал побитово тот же текст, что `-l ru` (`-dl` печатает в stderr `auto-detected language: ru (p = 0.997304)` и завершается).
- `-np` убирает около 8 КБ служебного шума Metal и загрузки модели в stderr. Остаются две строки `read_audio_data…`, ошибки и, с `-pp`, прогресс.
- **`-nt` (без меток времени) не использовать:** текст теряется. На turbo q5_0 WER 0,333 против 0,241, 213 слов против 234, целиком выпало «Определённый интеграл от 0 до 1 от x в квадрате равен 1 третье». У tiny выпал абзац с определением предела, у small WER 0,371 против 0,363.
- GPU (Metal) включён по умолчанию. `-ng` (только CPU) в 10 раз медленнее: turbo q5_0 расшифровал 95 с за 39 с против 3,7 с.
- **Потоки (`-t`)** на GPU почти ничего не меняют: 1 поток 4,2 с, 2 потока 3,7 с, 4 и больше 3,5 с (turbo q5_0, 95 с). Оставляем умолчание 4. На CPU больше потоков хуже: small `-ng` 19,3 с при `-t 4` и 24,3 с при `-t 10` (на этом Mac 4 производительных и 6 энергоэффективных ядер).
- `--prompt` (подсказка) эффект даёт мелкий и разный. WER без подсказки → с подсказкой «Лекция по математическому анализу: пределы, производные, интегралы, ряд Тейлора, формула Ньютона — Лейбница»: tiny 0,544 → 0,485, small 0,363 → 0,338, turbo q5_0 0,241 → 0,257 (хуже). Имя «Лейбниц» подсказка не исправила («Лиебница», «Леебница»). Решение о пользе откладываем до настоящей записи; пока подсказка необязательная.

### Формат вывода
stdout, построчно **по мере работы** (через канал строки приходили каждые несколько секунд, а не в конце):
```

[00:00:00.000 --> 00:00:05.880]   Добрый день! Сегодня у нас лекция по математическому анализу, тема, пределы и производные.
[00:00:06.240 --> 00:00:08.000]   Начнем с определения предела.
```
- Первая строка пустая; после `]` три пробела. Сегмент — фраза до 20 с (95 с лекции: 24 сегмента у turbo, 26 у tiny).
- Прогресс: `-pp` печатает в stderr `whisper_print_progress_callback: progress =  31%`, около 5 % за шаг (20 строк на 30 минут). Для интерфейса проще и точнее брать конец последнего сегмента из stdout и делить на длительность записи, которую мы знаем заранее.
- `-oj -of <путь без расширения>` пишет `<путь>.json` **в самом конце работы** (в stderr `output_json: saving output to …`), stdout при этом печатается как обычно. Структура (`raw/whisper-tiny-oj.json`): `transcription[]` с `offsets.from/to` в миллисекундах, `timestamps.from/to` (`00:00:03,200`) и `text` с ведущим пробелом. `-ojf` добавляет токены с вероятностями `p`: 138 КБ на 95 с (около 8 МБ на 90 минут), нам не нужно.
- Разбор stdout: `^\[(\d+):(\d\d):(\d\d)\.(\d{3}) --> (\d+):(\d\d):(\d\d)\.(\d{3})\]\s+(.*)$`. Строки без метки (пустая первая) пропускать.

### Ошибки
| ситуация | код | stdout | stderr |
|---|---|---|---|
| успех | 0 | сегменты | `read_audio_data: reading audio data from …`, `trying to decode with miniaudio` |
| нет файла модели | 3 | пусто | `error: model file not found '<путь>'` и справка |
| нет входного файла | 2 | пусто | `error: input file not found '<путь>'`, `error: no input files specified` и справка |
| звук не декодируется (пустой файл, текст вместо звука, m4a) | 11 | пусто | `read_audio_data: failed to read audio data`, `error: failed to read audio file '<путь>'`, `error: 1 input file(s) failed` |
| обрезанная модель (20 МБ из 78) | 134 | пусто | `error: failed to initialize whisper context`, `GGML_ASSERT([rsets->data count] == 0) failed` и бэктрейс |
| неизвестный флаг | **0** | пусто | `error: unknown argument: --no-such-flag` и справка |
| звук 0,1 с | 0 | пусто | только `read_audio_data…` |
| тишина, тон | 0 | галлюцинации (см. ниже) или пусто | то же |

Вывод: ошибка определяется по `код != 0` **или** строке `error:` в stderr (флаг с опечаткой даёт код 0). Пустой stdout при коде 0 — не ошибка, а «речи не найдено».

### Тишина, музыка и галлюцинации
- tiny на 60 с тишины: «АПЛОДИСМЕНТЫ» дважды; на синусоиде 30 с: «[музыка]».
- turbo q5_0 на 60 с тишины: «Редактор субтитров А.Семкин Корректор А.Егорова», «Корректор А.Кулакова»; на синусоиде: «Субтитры создавал DimaTorzok». Фразы из титров, которых в звуке нет, подтверждены.
- Пауза 120 с посреди двух кусков речи (`whisper-turbo-gap120`): без VAD три галлюцинации «Редактор субтитров А.Семкин Корректор А.Егоров» на 1:52, 2:22 и 2:52, а метка после паузы съезжает: «Добрый день.» стоит на 3:22–3:36, хотя речь началась в 3:35.
- `-sns` (`--suppress-nst`) на галлюцинации не повлиял.
- **VAD** (`--vad -vm ggml-silero-v5.1.2.bin`, 885 КБ, `https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin`): тишина даёт пустой вывод, пауза посреди лекции — ни одной галлюцинации, метки остаются в исходной шкале (второй кусок начался на 3:35), на обычной речи качество то же (WER 0,236 против 0,241). Чистую синусоиду VAD всё же принял за речь: одна строка длиной 0,48 с.
- Вывод: VAD включаем, когда файл модели VAD найден (необязательный, около 1 МБ), и **независимо от него** режем в коде известные фразы-галлюцинации: «Редактор субтитров», «Корректор», «Субтитры создавал/делал», «DimaTorzok», «АПЛОДИСМЕНТЫ», «[музыка]» (последние три из наблюдений выше; «Продолжение следует» и «Спасибо за просмотр» известны по практике, здесь не воспроизводились).
- Зацикливание: tiny на склейке из 19 повторов лекции (30 минут) застрял на одной фразе: «и деницы, стремящимся к нулю…» 21 раз подряд. Вход искусственный (один кусок повторён), turbo q5_0 на нём цикла не дал, но проверка повторов нужна.

### Модели
Расшифровка 95 с / 30 минут (склейка из 19 копий), M5, GPU:
| модель | файл | размер | WER (95 с) | терминов из 16 | время 95 с | время 30 мин | память 95 с / 30 мин |
|---|---|---|---|---|---|---|---|
| tiny | `ggml-tiny.bin` | 78 МБ | 0,544 | 9 | 2,1 с | 33 с | — / 0,63 ГБ |
| small | `ggml-small.bin` | 488 МБ | 0,363 | 15 | 3,7 с | 69 с | 0,96 / 1,18 ГБ |
| turbo q5_0 | `ggml-large-v3-turbo-q5_0.bin` | 574 МБ | 0,241 | 15 | 3,7 с | 70 с | 0,95 / 1,27 ГБ |
| turbo fp16 | `ggml-large-v3-turbo.bin` | 1,62 ГБ | 0,241 | 15 | 5,0 с | 87 с | 2,00 / 2,35 ГБ |

Память — «maximum resident set size» из `/usr/bin/time -l`. Не распознаются у small и turbo только имена («Лейбниц» → «лиебница», «леебница»).
- **Рекомендация: `ggml-large-v3-turbo-q5_0.bin`.** По качеству и терминам не хуже fp16 (текст отличается тремя мелочами: запятая, «1» против «единице», «трети» против «третье»), в 2,8 раза меньше файл, вдвое меньше памяти, на 20–27 % быстрее.
- `small` по размеру и скорости такой же, как turbo q5_0, а качество заметно хуже: в инструкции его не предлагаем. fp16 — запасной вариант «точнее»; выигрыш на шумной настоящей записи не проверен.
- Скорость на этом Mac: turbo q5_0 расшифровывает около 25 с звука за секунду. Для 90 минут это около 3,5 минут. Без GPU 0,4 с на секунду звука.

### Формулы в сыром тексте
Whisper пишет формулы сам и по-разному: small — `x^2+1=2x`, `x^3/3+c`, `sin(x)`, turbo — `f от x`, `x в квадрате плюс единица равна 2x`, `ε`, `δ`, `sin x`, `x0`. Очистка (этап 3) получает смесь слов и символов, и правило `[?$…$]` должно принимать оба вида.

### Отмена
`SIGTERM` и `SIGINT` останавливают `whisper-cli` за 0,01 с, процесс не остаётся. Код возврата: убит сигналом (`-15` и `-2` в Python `subprocess`, 143 в оболочке). Уже напечатанные строки остаются (через 8 с работы в stdout было 49 строк, до 3:10 звука), так что при отмене можно показать частичный результат. **Из фонового `&` в неинтерактивном bash `SIGINT` игнорируется** (процесс доработал до конца), в приложении сигнал нужно слать через `Process.terminate()`/`kill`.

### Длинные записи (6 часов)
`whisper-cli` читает весь звук в память и сразу считает спектрограмму, поэтому на старте у процесса пик, а потом память падает и держится ровно (`raw/whisper-6h.txt`). Проверено на склейке из 19×12 копий лекции: WAV 698 МБ, 6 ч 03 мин.
- Код 0, 834 с (26 с звука за секунду, как на 30 минутах), 5655 сегментов, последняя метка 06:03:26.980, `-pp` напечатал 20 строк.
- Память: пик 3,5 ГБ в первые 20–40 с, дальше 2,24 ГБ; «maximum resident set size» 3,73 ГБ, «peak memory footprint» 4,84 ГБ. Зависимость от длины: 95 с — 0,95 ГБ, 30 минут — 1,27 ГБ, 6 часов — 3,73 ГБ, то есть около 0,5 ГБ на час звука; для 90 минут около 1,6 ГБ.
- Текст целый: каждая из фраз лекции встретилась ровно 228 раз (19×12), фраз-галлюцинаций и зацикливания нет.
- Вывод: лимит 6 часов из плана (этап 1) оставляем. На Mac с 8 ГБ 6-часовая запись займёт почти всю память; в таком случае предупреждать заранее. Резать звук на части флагами `-ot`/`-d` не пробовал.

### Итог для реализации (расшифровка записей)
- Команда: `whisper-cli -m <модель> -f <audio.wav> -l <язык> -np` + необязательные `--prompt` и `--vad -vm <модель VAD>`. `-l` всегда задаём явно (по умолчанию английский, это перевод), `-nt` не используем.
- Звук: WAV 16 кГц моно 16 бит во временной папке; m4a из папки лекции каждый раз распаковывается заново, а WAV удаляется после расшифровки.
- Прогресс: из stdout (конец последнего сегмента / длительность). `-pp` не нужен.
- Результат: разбор stdout по регулярке выше; потоковый, поэтому при отмене сохраняется то, что успело напечататься.
- Ошибка: `код != 0` или строка `error:` в stderr. Классификация: 3 → нет модели, 2 → нет входного файла (ошибка приложения), 11 → звук не читается, 134 → модель повреждена или несовместима, остальное → `processFailed` с последними строками stderr.
- Таймаут: длительность записи плюс 5 минут. Без GPU расшифровка идёт в 2,4 раза быстрее реального времени, на GPU в 25 раз.
- Бинарник: `/opt/homebrew/bin/whisper-cli`, `/usr/local/bin/whisper-cli`, затем `PATH` и ручной путь. Модель: только ручной путь (стандартного каталога нет); рекомендуемый файл `ggml-large-v3-turbo-q5_0.bin`.
- После расшифровки: убрать фразы-галлюцинации, схлопнуть подряд идущие повторы одной строки.

## Anki: `\ce{}` в MathJax

Anki (2.1+, AnkiMobile, AnkiDroid 2.9+) рендерит формулы встроенным MathJax, и [расширение mhchem в него встроено](https://docs.ankiweb.net/manual/math): `\ce{…}` работает без настройки. Разделители только `\(…\)` и `\[…\]`, `$` не поддерживается — значит, конвертация из раздела 8 ТЗ нужна. Отдельная оговорка в инструкции не требуется.

## Итог для реализации (этап 3)

- Единственный движок v1 — `ClaudeCodeEngine` с командой из раздела «Итоговая команда». Длинные промпты передавать через stdin.
- Поиск бинарника: `claude` — нативный Mach-O, обычно `~/.local/bin/claude` (симлинк на `~/.local/share/claude/versions/<версия>`); `node` не нужен. Список мест из ТЗ 2.4 подходит, `~/.local/bin` в нём уже есть.
- Успех: `exit == 0 && is_error == false`. Ошибка: всё остальное; причину брать из `result`, при нечитаемом stdout — из stderr. `subtype` не использовать.
- Классификация: `Not logged in` → `notAuthenticated`; `api_error_status == 404` или `unrecognized_model` в stderr → ошибка модели (показывать как `processFailed` с понятным текстом «модель недоступна»); шаблоны лимита → `rateLimited(resetAt:)`; exit 127 / нет файла → `binaryNotFound`.
- Фактическая модель для `meta.json` — ключ из `modelUsage`.
