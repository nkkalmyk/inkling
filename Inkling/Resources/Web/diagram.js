// Графики и схемы из блоков ```plot и ```svg конспекта. Без зависимостей и без DOM: строка в строку.
// plot — JSON с формулами, который считается здесь же (модель не присылает готовых координат);
// svg — разметка от модели, пропускается только через белый список элементов и атрибутов.
(function (global) {
  'use strict';

  function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function failure(source, reason) {
    return '<div class="diagram-error">' + esc(reason) + '</div><pre><code>' + esc(source) + '</code></pre>';
  }

  // ---- Выражения: x, числа, + - * / ^, скобки, pi, e, sin cos tan exp ln log sqrt abs ----

  var FUNCS = {
    sin: Math.sin, cos: Math.cos, tan: Math.tan, exp: Math.exp, ln: Math.log, log: Math.log10,
    sqrt: Math.sqrt, abs: Math.abs, asin: Math.asin, acos: Math.acos, atan: Math.atan,
    sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh
  };
  var CONSTS = { pi: Math.PI, e: Math.E };

  function tokenize(src) {
    var tokens = [];
    var re = /\s*(?:(\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+)|([A-Za-z_]\w*)|(\*\*|[-+*\/^(),]))/y;
    var pos = 0;
    src = src.replace(/[−–]/g, '-').replace(/[×·]/g, '*').replace(/π/g, 'pi');
    while (pos < src.length) {
      re.lastIndex = pos;
      var m = re.exec(src);
      if (!m) {
        if (/^\s*$/.test(src.slice(pos))) break;
        throw new Error('Недопустимый символ в выражении «' + src + '»');
      }
      pos = re.lastIndex;
      if (m[1] !== undefined) tokens.push({ t: 'num', v: parseFloat(m[1]) });
      else if (m[2] !== undefined) tokens.push({ t: 'id', v: m[2].toLowerCase() });
      else tokens.push({ t: 'op', v: m[3] === '**' ? '^' : m[3] });
    }
    return tokens;
  }

  // Возвращает функцию x -> число.
  function compile(src) {
    if (typeof src !== 'string' || src.length === 0 || src.length > 200) throw new Error('Пустое или слишком длинное выражение');
    var tokens = tokenize(src);
    var i = 0;
    function peek() { return tokens[i]; }
    function isOp(v) { var t = tokens[i]; return t && t.t === 'op' && t.v === v; }

    function parseExpr() {
      var left = parseTerm();
      while (isOp('+') || isOp('-')) {
        var op = tokens[i++].v, right = parseTerm();
        left = (function (l, r, o) { return function (x) { return o === '+' ? l(x) + r(x) : l(x) - r(x); }; })(left, right, op);
      }
      return left;
    }
    function startsFactor() {
      var t = peek();
      return t && (t.t === 'num' || t.t === 'id' || (t.t === 'op' && t.v === '('));
    }
    function parseTerm() {
      var left = parseUnary();
      for (;;) {
        if (isOp('*') || isOp('/')) {
          var op = tokens[i++].v, right = parseUnary();
          left = (function (l, r, o) { return function (x) { return o === '*' ? l(x) * r(x) : l(x) / r(x); }; })(left, right, op);
        } else if (startsFactor()) {  // неявное умножение: 2x, 3(x+1), x sin(x)
          var right2 = parseUnary();
          left = (function (l, r) { return function (x) { return l(x) * r(x); }; })(left, right2);
        } else {
          return left;
        }
      }
    }
    function parseUnary() {
      if (isOp('-')) { i++; var v = parseUnary(); return function (x) { return -v(x); }; }
      if (isOp('+')) { i++; return parseUnary(); }
      return parsePower();
    }
    function parsePower() {
      var base = parsePrimary();
      if (isOp('^')) {
        i++;
        var exp = parseUnary();  // правоассоциативно, допускает x^-1
        return function (x) { return Math.pow(base(x), exp(x)); };
      }
      return base;
    }
    function parsePrimary() {
      var t = tokens[i++];
      if (!t) throw new Error('Выражение оборвано');
      if (t.t === 'num') return function () { return t.v; };
      if (t.t === 'op' && t.v === '(') {
        var inner = parseExpr();
        if (!isOp(')')) throw new Error('Нет закрывающей скобки');
        i++;
        return inner;
      }
      if (t.t === 'id') {
        if (t.v === 'x') return function (x) { return x; };
        if (Object.prototype.hasOwnProperty.call(CONSTS, t.v)) { var c = CONSTS[t.v]; return function () { return c; }; }
        if (Object.prototype.hasOwnProperty.call(FUNCS, t.v)) {
          if (!isOp('(')) throw new Error('После «' + t.v + '» нужна скобка');
          i++;
          var arg = parseExpr();
          if (!isOp(')')) throw new Error('Нет закрывающей скобки');
          i++;
          var fn = FUNCS[t.v];
          return function (x) { return fn(arg(x)); };
        }
        throw new Error('Неизвестное имя «' + t.v + '»');
      }
      throw new Error('Неожиданный символ в выражении');
    }

    var f = parseExpr();
    if (i < tokens.length) throw new Error('Лишнее в выражении «' + src + '»');
    return f;
  }

  // ---- График ----

  function niceStep(span, target) {
    var raw = span / target;
    var pow = Math.pow(10, Math.floor(Math.log10(raw)));
    var f = raw / pow;
    return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * pow;
  }

  function fmt(v) {
    var r = Math.round(v * 1e6) / 1e6;
    return String(r).replace('-', '−');
  }

  function plot(source) {
    var spec;
    try { spec = JSON.parse(source); } catch (e) { return failure(source, 'График не отрисован: неверный JSON'); }
    try {
      if (!spec || typeof spec !== 'object') throw new Error('Ожидался объект');
      var xr = spec.x;
      if (!Array.isArray(xr) || xr.length !== 2 || !isFinite(xr[0]) || !isFinite(xr[1]) || !(xr[0] < xr[1])) {
        throw new Error('Нужен диапазон x: [мин, макс]');
      }
      var funcs = (spec.functions || []).slice(0, 4).map(function (f) {
        return { fn: compile(f.expr), label: typeof f.label === 'string' ? f.label : String(f.expr) };
      });
      var points = (Array.isArray(spec.points) ? spec.points : []).slice(0, 20).filter(function (p) {
        return p && isFinite(p.x) && isFinite(p.y);
      });
      if (!funcs.length && !points.length) throw new Error('Нет ни функций, ни точек');

      var N = 400, x0 = xr[0], x1 = xr[1];
      var curves = funcs.map(function (f) {
        var pts = [];
        for (var k = 0; k <= N; k++) {
          var x = x0 + (x1 - x0) * k / N;
          var y = f.fn(x);
          pts.push(isFinite(y) && Math.abs(y) < 1e9 ? [x, y] : null);
        }
        return pts;
      });

      var y0, y1;
      if (Array.isArray(spec.y) && spec.y.length === 2 && isFinite(spec.y[0]) && isFinite(spec.y[1]) && spec.y[0] < spec.y[1]) {
        y0 = spec.y[0]; y1 = spec.y[1];
      } else {
        var ys = [];
        curves.forEach(function (c) { c.forEach(function (p) { if (p) ys.push(p[1]); }); });
        points.forEach(function (p) { ys.push(p.y); });
        if (!ys.length) throw new Error('Функция нигде не определена на заданном диапазоне');
        ys.sort(function (a, b) { return a - b; });
        // Без 2% крайних значений: вертикальные асимптоты не должны сплющить график.
        y0 = ys[Math.floor(ys.length * 0.02)];
        y1 = ys[Math.ceil(ys.length * 0.98) - 1];
        if (y0 === y1) { y0 -= 1; y1 += 1; }
        var pad = (y1 - y0) * 0.1;
        y0 -= pad; y1 += pad;
      }

      var W = 480, H = 320, L = 44, R = 16, T = 16, B = 32;
      var sx = function (x) { return L + (x - x0) / (x1 - x0) * (W - L - R); };
      var sy = function (y) { return H - B - (y - y0) / (y1 - y0) * (H - T - B); };
      var out = [];
      var xs = niceStep(x1 - x0, 6), ysStep = niceStep(y1 - y0, 5);
      for (var gx = Math.ceil(x0 / xs) * xs; gx <= x1 + 1e-9; gx += xs) {
        out.push('<line class="grid" x1="' + sx(gx).toFixed(1) + '" y1="' + T + '" x2="' + sx(gx).toFixed(1) + '" y2="' + (H - B) + '"/>');
        out.push('<text class="tick" x="' + sx(gx).toFixed(1) + '" y="' + (H - B + 16) + '" text-anchor="middle">' + fmt(gx) + '</text>');
      }
      for (var gy = Math.ceil(y0 / ysStep) * ysStep; gy <= y1 + 1e-9; gy += ysStep) {
        out.push('<line class="grid" x1="' + L + '" y1="' + sy(gy).toFixed(1) + '" x2="' + (W - R) + '" y2="' + sy(gy).toFixed(1) + '"/>');
        out.push('<text class="tick" x="' + (L - 6) + '" y="' + (sy(gy) + 4).toFixed(1) + '" text-anchor="end">' + fmt(gy) + '</text>');
      }
      if (x0 <= 0 && x1 >= 0) out.push('<line class="axis" x1="' + sx(0).toFixed(1) + '" y1="' + T + '" x2="' + sx(0).toFixed(1) + '" y2="' + (H - B) + '"/>');
      if (y0 <= 0 && y1 >= 0) out.push('<line class="axis" x1="' + L + '" y1="' + sy(0).toFixed(1) + '" x2="' + (W - R) + '" y2="' + sy(0).toFixed(1) + '"/>');

      curves.forEach(function (pts, idx) {
        var d = '', pen = false;
        pts.forEach(function (p) {
          if (!p || p[1] < y0 - (y1 - y0) || p[1] > y1 + (y1 - y0)) { pen = false; return; }
          d += (pen ? 'L' : 'M') + sx(p[0]).toFixed(1) + ' ' + sy(p[1]).toFixed(1);
          pen = true;
        });
        out.push('<path class="curve c' + idx + '" d="' + d + '"/>');
      });
      points.forEach(function (p) {
        out.push('<circle class="dot" cx="' + sx(p.x).toFixed(1) + '" cy="' + sy(p.y).toFixed(1) + '" r="3.5"/>');
        if (typeof p.label === 'string') {
          out.push('<text class="plabel" x="' + (sx(p.x) + 6).toFixed(1) + '" y="' + (sy(p.y) - 6).toFixed(1) + '">' + esc(p.label) + '</text>');
        }
      });

      var legend = funcs.map(function (f, idx) {
        return '<span class="legend-item"><i class="swatch c' + idx + '"></i>' + esc(f.label) + '</span>';
      }).join('');
      var title = typeof spec.title === 'string' && spec.title ? '<figcaption>' + esc(spec.title) + '</figcaption>' : '';
      return '<figure class="diagram plot"><svg viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="' +
        esc(typeof spec.title === 'string' ? spec.title : 'График') + '">' + out.join('') + '</svg>' +
        (legend ? '<div class="legend">' + legend + '</div>' : '') + title + '</figure>';
    } catch (e) {
      return failure(source, 'График не отрисован: ' + (e && e.message || e));
    }
  }

  // ---- Схема (SVG от модели через белый список) ----

  var TAGS = {
    svg: 1, g: 1, path: 1, line: 1, rect: 1, circle: 1, ellipse: 1, polygon: 1, polyline: 1,
    text: 1, tspan: 1, defs: 1, marker: 1, title: 1, desc: 1
  };
  var ATTRS = {
    viewbox: 'viewBox', x: 'x', y: 'y', x1: 'x1', y1: 'y1', x2: 'x2', y2: 'y2', cx: 'cx', cy: 'cy', r: 'r', rx: 'rx', ry: 'ry',
    d: 'd', points: 'points', transform: 'transform', fill: 'fill', stroke: 'stroke', 'stroke-width': 'stroke-width',
    'stroke-linecap': 'stroke-linecap', 'stroke-linejoin': 'stroke-linejoin', 'stroke-dasharray': 'stroke-dasharray',
    'font-size': 'font-size', 'font-weight': 'font-weight', 'text-anchor': 'text-anchor',
    'dominant-baseline': 'dominant-baseline', 'marker-end': 'marker-end', 'marker-start': 'marker-start',
    id: 'id', refx: 'refX', refy: 'refY', markerwidth: 'markerWidth', markerheight: 'markerHeight', orient: 'orient',
    opacity: 'opacity', dx: 'dx', dy: 'dy'
  };
  var SAFE_VALUE = /^[\w\s.,#%()+\-:'"]*$/;  // без `;`, `<`, `&`, `\`, `/` и `@`

  function safeValue(name, value) {
    if (value.length > 2000 || !SAFE_VALUE.test(value)) return false;
    var lower = value.toLowerCase();
    if (/(javascript|data:|expression)/.test(lower)) return false;
    if (/url\(/.test(lower) && !/^url\(#[\w-]+\)$/.test(lower.trim())) return false;
    return true;
  }

  function svg(source) {
    var tagRe = /<\s*(\/?)\s*([A-Za-z][\w:-]*)((?:\s+[\w:-]+(?:\s*=\s*(?:"[^"]*"|'[^']*'))?)*)\s*(\/?)\s*>/g;
    var out = [];
    var stack = [];
    var last = 0, m, sawRoot = false;
    var body = source.replace(/<!--[\s\S]*?-->/g, '');
    while ((m = tagRe.exec(body)) !== null) {
      var text = body.slice(last, m.index);
      if (text && stack.length) out.push(esc(text.replace(/<[^>]*$/, '')));
      last = tagRe.lastIndex;
      var closing = m[1] === '/', name = m[2].toLowerCase(), selfClose = m[4] === '/';
      if (!TAGS[name]) continue;
      if (closing) {
        var at = stack.lastIndexOf(name);
        if (at === -1) continue;
        while (stack.length > at) out.push('</' + stack.pop() + '>');
        continue;
      }
      if (!sawRoot) {
        if (name !== 'svg') return failure(source, 'Схема не отрисована: ожидался элемент svg');
        sawRoot = true;
      }
      var attrs = '';
      var attrRe = /([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'))?/g, a;
      while ((a = attrRe.exec(m[3])) !== null) {
        var key = a[1].toLowerCase();
        var val = a[2] !== undefined ? a[2] : (a[3] !== undefined ? a[3] : '');
        if (!Object.prototype.hasOwnProperty.call(ATTRS, key)) continue;
        if (!safeValue(key, val)) continue;
        attrs += ' ' + ATTRS[key] + '="' + esc(val) + '"';
      }
      out.push('<' + name + attrs + (selfClose ? '/>' : '>'));
      if (!selfClose) stack.push(name);
    }
    if (!sawRoot) return failure(source, 'Схема не отрисована: нет элемента svg');
    while (stack.length) out.push('</' + stack.pop() + '>');
    return '<figure class="diagram scheme">' + out.join('') + '</figure>';
  }

  global.InklingDiagram = { plot: plot, svg: svg, compile: compile };
})(this);
