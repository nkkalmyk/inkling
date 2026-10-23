// Рендер конспекта: Markdown (markdown-it) + формулы (KaTeX + mhchem).
// Формулы вынимаются из текста до markdown-it, чтобы `_`, `*` и `\` внутри них не превращались в разметку,
// а после рендера подставляются обратно уже свёрстанными. Чистая функция строки в строку: без DOM.
(function (global) {
  'use strict';

  var md = global.markdownit({ html: false, linkify: true, typographer: false, breaks: false });
  var PH = 'INKLINGMATH';

  // Удалённые картинки не грузим: ответ модели мог собрать адрес с данными лекции (канал утечки).
  // Вместо них — подпись; картинки data: и относительные остаются.
  var defaultImage = md.renderer.rules.image;
  md.renderer.rules.image = function (tokens, idx, options, env, self) {
    var src = tokens[idx].attrGet('src') || '';
    if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(src) && !/^data:/i.test(src)) {
      return escapeHTML(tokens[idx].content || '');
    }
    return defaultImage(tokens, idx, options, env, self);
  };

  // ```plot и ```svg — графики и схемы из «Дополнить» (diagram.js). Остальные блоки кода — как обычно.
  var defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = function (tokens, idx, options, env, self) {
    var info = (tokens[idx].info || '').trim().toLowerCase();
    var diagram = global.InklingDiagram;
    if (diagram && info === 'plot') return diagram.plot(tokens[idx].content);
    if (diagram && info === 'svg') return diagram.svg(tokens[idx].content);
    return defaultFence ? defaultFence(tokens, idx, options, env, self) : self.renderToken(tokens, idx, options);
  };

  // Находит формулы $...$ и $$...$$ вне кода и заменяет их метками INKLINGMATH<n>X.
  function extractMath(src) {
    var formulas = [];
    var parts = [];
    var buffer = [];
    var inFence = null;

    function flush() {
      if (buffer.length) {
        parts.push(scan(buffer.join('\n'), formulas));
        buffer = [];
      }
    }

    src.split('\n').forEach(function (line) {
      var fence = line.match(/^\s*(```+|~~~+)/);
      if (inFence) {
        parts.push(line);
        if (fence && fence[1][0] === inFence[0] && fence[1].length >= inFence.length) inFence = null;
        return;
      }
      if (fence) {
        flush();
        inFence = fence[1];
        parts.push(line);
        return;
      }
      buffer.push(line);
    });
    flush();
    return { text: parts.join('\n'), formulas: formulas };
  }

  function scan(text, formulas) {
    var out = '';
    var i = 0;
    var n = text.length;
    while (i < n) {
      var c = text[i];
      if (c === '\\' && text[i + 1] === '$') { out += '\\$'; i += 2; continue; }
      if (c === '`') {
        var run = 0;
        while (text[i + run] === '`') run++;
        var ticks = text.substr(i, run);
        var close = text.indexOf(ticks, i + run);
        while (close !== -1 && text[close + run] === '`') close = text.indexOf(ticks, close + run + 1);
        if (close === -1) { out += ticks; i += run; continue; }
        out += text.slice(i, close + run);
        i = close + run;
        continue;
      }
      if (c === '$' && text[i + 1] === '$') {
        var end = text.indexOf('$$', i + 2);
        if (end !== -1) {
          formulas.push({ tex: text.slice(i + 2, end), display: true });
          out += PH + (formulas.length - 1) + 'X';
          i = end + 2;
          continue;
        }
      }
      if (c === '$') {
        var j = findInlineEnd(text, i);
        if (j !== -1) {
          formulas.push({ tex: text.slice(i + 1, j), display: false });
          out += PH + (formulas.length - 1) + 'X';
          i = j + 1;
          continue;
        }
      }
      out += c;
      i++;
    }
    return out;
  }

  // Правила Pandoc: после открывающего $ нет пробела, перед закрывающим нет пробела, после него не цифра;
  // формула не выходит за пустую строку.
  function findInlineEnd(text, start) {
    var next = text[start + 1];
    if (next === undefined || /\s/.test(next)) return -1;
    for (var j = start + 1; j < text.length; j++) {
      var ch = text[j];
      if (ch === '\n' && text[j + 1] === '\n') return -1;
      if (ch === '\\') { j++; continue; }
      if (ch === '$') {
        if (/\s/.test(text[j - 1])) continue;
        if (/[0-9]/.test(text[j + 1] || '')) continue;
        return j;
      }
    }
    return -1;
  }

  function escapeHTML(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  function renderFormula(f) {
    try {
      var html = global.katex.renderToString(f.tex, {
        displayMode: f.display, throwOnError: false, strict: 'ignore', trust: false, output: 'html'
      });
      return f.display ? '<div class="math-display">' + html + '</div>' : html;
    } catch (e) {
      return '<span class="katex-error" title="' + escapeHTML(String(e && e.message || e)).replace(/"/g, '&quot;') + '">' + escapeHTML(f.tex) + '</span>';
    }
  }

  function toHTML(markdown) {
    var extracted = extractMath(markdown || '');
    var html = md.render(extracted.text);
    // `[?слово]` — догадка модели по смыслу там, где почерк не читается; до подстановки формул, пока они ещё метки.
    html = html.replace(/\[\?([^\]\n<>]+)\]/g, '<mark class="guess" title="Догадка модели по смыслу: проверьте по фото">$1</mark>');
    // Формула одна в абзаце — выключенная, без обёртки <p>.
    html = html.replace(new RegExp('<p>(' + PH + '(\\d+)X)</p>', 'g'), function (whole, all, idx) {
      var f = extracted.formulas[+idx];
      if (!f) return whole;  // метка из самого текста, а не от extractMath
      return f.display ? renderFormula(f) : '<p>' + renderFormula(f) + '</p>';
    });
    html = html.replace(new RegExp(PH + '(\\d+)X', 'g'), function (whole, idx) {
      var f = extracted.formulas[+idx];
      return f ? renderFormula(f) : whole;
    });
    html = html.replace(/\[неразборчиво\]/g, '<mark class="illegible">[неразборчиво]</mark>');
    html = html.replace(/<blockquote>\s*<p>(⚠️|⚠)/g, '<blockquote class="callout warn"><p>$1');
    html = html.replace(/<blockquote>\s*<p>(📎)/g, '<blockquote class="callout slides"><p>$1');
    html = html.replace(/<blockquote>\s*<p>(💡)/g, '<blockquote class="callout explain"><p>$1');
    html = html.replace(/<blockquote>\s*<p>(📝)/g, '<blockquote class="callout example"><p>$1');
    html = html.replace(/<blockquote>\s*<p>(🔗)/g, '<blockquote class="callout link"><p>$1');
    html = html.replace(/<h2>(\s*🧭)/g, '<h2 class="summary-heading">$1');
    return structure(html);
  }

  // ---- Структура учебного конспекта: якоря заголовков, ссылки в оглавлении, оформление определений и задач ----

  function plain(html) {
    return html.replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim();
  }

  // Название без номера и знаков в конце: «1.2. Закон Гесса:» и «Закон Гесса» сравниваются как равные.
  function headingKey(html) {
    return plain(html).replace(/^\d+(?:\.\d+)*\.?\s*/, '').replace(/[\s.:;,]+$/, '').toLowerCase();
  }

  // Конец списка `<ol>`/`<ul>`, начинающегося в позиции start, с учётом вложенных списков.
  function listEnd(html, start) {
    var re = /<(\/?)(ul|ol)\b[^>]*>/g;
    re.lastIndex = start;
    var depth = 0, m;
    while ((m = re.exec(html)) !== null) {
      depth += m[1] ? -1 : 1;
      if (depth === 0) return re.lastIndex;
    }
    return -1;
  }

  var DEFINITION = /^(?:Закон|Теорема|Определение|Правило|Принцип|Следствие|Лемма|Аксиома|Постулат|Уравнение|Формула|Свойство)/i;

  function structure(html) {
    // 1. Якоря у заголовков h1–h3 (по порядку) и таблица заголовков для оглавления.
    var headings = [];
    html = html.replace(/<h([1-3])((?: [^>]*)?)>([\s\S]*?)<\/h\1>/g, function (whole, level, attrs, inner) {
      var id = 'sec-' + (headings.length + 1);
      headings.push({ id: id, key: headingKey(inner) });
      return '<h' + level + attrs + ' id="' + id + '">' + inner + '</h' + level + '>';
    });

    // 2. Оглавление: пункты, совпавшие по названию с заголовком, становятся ссылками.
    var toc = /<h2[^>]*>\s*Оглавление\s*<\/h2>\s*/.exec(html);
    if (toc) {
      var start = toc.index + toc[0].length;
      if (/^<(?:ol|ul)\b/.test(html.slice(start))) {
        var end = listEnd(html, start);
        if (end !== -1) {
          var list = html.slice(start, end).replace(/<li>([\s\S]*?)(?=<(?:ul|ol)\b|<\/li>)/g, function (whole, inner) {
            var key = headingKey(inner);
            var target = key && headings.filter(function (h) { return h.key === key; })[0];
            return target ? '<li><a href="#' + target.id + '">' + inner.trim() + '</a>' : whole;
          });
          html = html.slice(0, start) + '<nav class="toc">' + list + '</nav>' + html.slice(end);
        }
      }
    }

    // 3. Условие, решение и ответ задач; определения и законы в начале абзаца.
    html = html.replace(/<p><strong>\s*Условие:?\s*<\/strong>/g, '<p class="task task-condition"><strong>Условие:</strong>');
    html = html.replace(/<p><strong>\s*Решение:?\s*<\/strong>/g, '<p class="task task-solution"><strong>Решение:</strong>');
    html = html.replace(/<p><strong>\s*Ответ:?\s*<\/strong>/g, '<p class="task task-answer"><strong>Ответ:</strong>');
    html = html.replace(/<p><strong>([^<]{3,120}?)<\/strong>/g, function (whole, title) {
      return DEFINITION.test(title) && /[:.]\s*$|\)\s*:?\s*$/.test(title) ? '<p class="definition"><strong>' + title + '</strong>' : whole;
    });
    return html;
  }

  global.InklingRender = { toHTML: toHTML, extractMath: extractMath };
})(this);
