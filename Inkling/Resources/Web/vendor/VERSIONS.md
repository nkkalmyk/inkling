# Сторонние JS-ассеты

Версии зафиксированы, файлы взяты из npm-пакетов как есть (`npm pack`), без изменений.

| Пакет | Версия | Файлы | Лицензия |
|---|---|---|---|
| katex | 0.18.10 | `katex/katex.min.js`, `katex/katex.min.css`, `katex/contrib/mhchem.min.js`, `katex/fonts/*.woff2` | MIT |
| markdown-it | 15.0.2 | `markdown-it/markdown-it.umd.min.js` | MIT |

Из шрифтов KaTeX оставлены только `.woff2`: WebKit берёт их первыми, остальные форматы не нужны.
