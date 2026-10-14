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

## Gemini CLI (`gemini`)

_Не установлен: на машине нет `node` и `npm`. Раздел будет дописан после установки (`npm install -g @google/gemini-cli`) и входа через Google-аккаунт._
