import { clamp, percent } from "editor/geometry"
import { each, selectionLabel, setText } from "editor/dom"
import { Box } from "editor/box"

// Uses only authorized, fingerprinted word maps from the file's own text
// (pages without data-words-url are scans/images). Proposes boxes only; never supplies PDF text.
export function WordTools(editor) {
  this.editor = editor;
  this.form = editor.form;
  this.status = this.form.querySelector('[data-word-status]');
  this.statusText = this.status && this.status.textContent;
  this.targetPage = null;
  this.generation = 0;
  this.selected = [];
  this.selectedPage = null;
  this.currentRequest = null;
  // Kept, not looked up in the form each time: Find can sit outside it.
  this.tools = this.form.querySelector('[data-word-tools]');
  this.query = this.form.querySelector('[data-word-query]');
  this.results = this.form.querySelector('[data-word-results]');
  this.selectButton = this.form.querySelector('[data-redact-words]');
  if (!this.status || !editor.pages.some(function (page) { return page.element.hasAttribute('data-words-url'); })) { return; }
  var tools = this;
  each(this.form, '[data-word-tools], [data-mode-select], [data-redact-words], [data-clear-selection]', function (element) { element.hidden = false; });
  this.form.querySelector('[data-mode-select]').addEventListener('click', function () { if (!editor.busy) { editor.setMode('select'); } }, { signal: editor.signal });
  this.selectButton.addEventListener('pointerdown', function (event) { event.preventDefault(); }, { signal: editor.signal });
  this.selectButton.addEventListener('click', function () {
    tools.addBoxes(tools.selectedPage, tools.selected, 'Redacted selected text');
    tools.clearSelection();
    var selection = window.getSelection();
    if (selection) { selection.removeAllRanges(); }
  }, { signal: editor.signal });
  this.form.querySelector('[data-clear-selection]').addEventListener('click', function () { tools.clearSelection(); }, { signal: editor.signal });
  document.addEventListener('selectionchange', function () { tools.nativeSelection(); }, { signal: editor.signal });
  editor.viewport.addEventListener('scroll', function () {
    window.clearTimeout(tools.scrollTimer);
    tools.scrollTimer = window.setTimeout(function () {
      var current = editor.currentPage();
      if (editor.mode === 'select' && !editor.busy && tools.targetPage !== current) { tools.load(current); }
    }, 150);
  }, { passive: true });
  this.tools.querySelector('[data-word-find]').addEventListener('click', function () { tools.find(); }, { signal: editor.signal });
  this.tools.querySelector('[data-word-stop]').addEventListener('click', function () { tools.stop(); tools.message('Find stopped. Remaining pages have not been checked.'); }, { signal: editor.signal });
  this.query.addEventListener('keydown', function (event) {
    if (event.key === 'Enter') { event.preventDefault(); tools.find(); }
    if (event.key === 'Escape') { event.preventDefault(); tools.stop(); }
  }, { signal: editor.signal });
}

WordTools.prototype.destroy = function () {
  window.clearTimeout(this.scrollTimer);
  this.generation += 1;
  if (this.currentRequest) { this.currentRequest.abort(); this.currentRequest = null; }
  if (this.results) { this.results.textContent = ''; }
  this.clearSelection();
  if (this.tools) {
    var stop = this.tools.querySelector('[data-word-stop]');
    if (stop) { stop.disabled = true; }
    this.progress('');
  }
  if (this.status) { this.status.textContent = this.statusText; }
};

WordTools.prototype.message = function (text) { setText(this.status, text); };
// Page by page, out of any live region: only the start and the result are announced.
WordTools.prototype.progress = function (text) { setText(this.tools.querySelector('[data-word-progress]'), text); };
WordTools.prototype.stop = function (keepPersonal) {
  if (this.personal && !keepPersonal) { this.personal.invalidate(); }
  this.generation += 1;
  if (this.currentRequest) { this.currentRequest.abort(); this.currentRequest = null; }
  var stop = this.tools.querySelector('[data-word-stop]');
  if (stop) { stop.disabled = true; }
};
WordTools.prototype.clearSelection = function () {
  this.selected = [];
  this.selectedPage = null;
  this.keyAnchor = null;
  this.keyAnchorPage = null;
  if (this.selectButton) { this.selectButton.disabled = true; }
  each(this.form, '.redaction-word', function (span) { span.classList.remove('is-selected'); span.setAttribute('aria-pressed', 'false'); });
};

WordTools.prototype.validate = function (map, page) {
  if (!map || String(map.page) !== page.number || map.version !== page.element.getAttribute('data-words-version')) { throw new Error('stale'); }
  if (['ready', 'partial', 'masked', 'unavailable'].indexOf(map.state) < 0 || !Array.isArray(map.words) || map.words.length > 5000) { throw new Error('invalid'); }
  var ids = {};
  map.words.forEach(function (word) {
    if (typeof word.id !== 'string' || word.id.length > 30 || ids[word.id] || typeof word.text !== 'string' || !word.text.length || word.text.length > 500 ||
        typeof word.line !== 'string' || word.line.length > 64 ||
        !Array.isArray(word.box) || word.box.length !== 4 || !word.box.every(function (n) { return Number.isFinite(n) && n >= 0 && n <= 1; }) ||
        word.box[2] <= word.box[0] || word.box[3] <= word.box[1]) { throw new Error('invalid'); }
    ids[word.id] = true;
  });
  if (map.state !== 'ready' && map.state !== 'partial' && map.words.length) { throw new Error('invalid'); }
  return map;
};

WordTools.prototype.fetchPage = async function (page, generation) {
  var url = new URL(page.element.getAttribute('data-words-url'), window.location.href);
  if (url.origin !== window.location.origin) { throw new Error('invalid'); }
  var controller = new AbortController();
  this.currentRequest = controller;
  var response = await fetch(url.href, { credentials: 'same-origin', cache: 'no-store', redirect: 'error', signal: controller.signal, headers: { Accept: 'application/json' } });
  if (generation !== this.generation) { throw new Error('cancelled'); }
  if ([401, 403, 404, 409].indexOf(response.status) >= 0) { throw new Error('stale'); }
  if (!response.ok) { throw new Error('unavailable'); }
  var text = await response.text();
  if (text.length > 2000000) { throw new Error('invalid'); }
  if (generation !== this.generation) { throw new Error('cancelled'); }
  this.currentRequest = null;
  return this.validate(JSON.parse(text), page);
};

WordTools.prototype.dropMap = function (page) {
  if (page.wordLayer) { page.wordLayer.remove(); }
  page.wordLayer = null;
  page.wordMap = null;
  if (this.selectedPage === page) { this.clearSelection(); }
};

WordTools.prototype.showMap = function (page, map) {
  this.dropMap(page);
  page.wordMap = map;
  if (!map.words.length) { return; }
  var layer = document.createElement('div');
  layer.className = 'redaction-word-layer';
  layer.setAttribute('role', 'group');
  layer.setAttribute('aria-hidden', String(this.editor.mode !== 'select'));
  layer.setAttribute('aria-label', 'Words on page ' + page.number + '. Use arrows to move, Space to select, Shift and arrows to extend.');
  page.wordLayer = layer;
  var tools = this;
  map.words.forEach(function (word, index) {
    var span = document.createElement('span');
    span.className = 'redaction-word';
    span.textContent = word.text + ' ';
    span.setAttribute('role', 'button');
    span.setAttribute('aria-pressed', 'false');
    span.setAttribute('data-word-index', index);
    span.tabIndex = tools.editor.mode === 'select' && index === 0 ? 0 : -1;
    span.style.left = percent(word.box[0]); span.style.top = percent(word.box[1]);
    span.style.width = percent(word.box[2] - word.box[0]); span.style.height = percent(word.box[3] - word.box[1]);
    span.addEventListener('click', function () {
      var selection = window.getSelection();
      if (!selection || selection.isCollapsed) { tools.choose(page, [word]); }
    });
    span.addEventListener('keydown', function (event) {
      if (event.key === ' ' || event.key === 'Enter') { event.preventDefault(); tools.choose(page, [word]); }
      var direction = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: 1, ArrowUp: -1 }[event.key];
      if (!direction) { return; }
      event.preventDefault();
      var next = clamp(index + direction, 0, map.words.length - 1);
      if (event.shiftKey) {
        var anchor = tools.keyAnchorPage === page && tools.keyAnchor !== null ? tools.keyAnchor : index;
        tools.choose(page, map.words.slice(Math.min(anchor, next), Math.max(anchor, next) + 1));
        tools.keyAnchor = anchor; tools.keyAnchorPage = page;
      }
      each(layer, '.redaction-word', function (node) { node.tabIndex = -1; });
      layer.children[next].tabIndex = 0;
      layer.children[next].focus();
    });
    layer.appendChild(span);
  });
  page.sheet.appendChild(layer);
  this.size();
};

WordTools.prototype.size = function () {
  this.editor.pages.forEach(function (page) {
    if (!page.wordLayer || !page.wordMap) { return; }
    var height = page.sheet.getBoundingClientRect().height;
    each(page.wordLayer, '.redaction-word', function (span) {
      var word = page.wordMap.words[Number(span.getAttribute('data-word-index'))];
      span.style.fontSize = Math.max(1, (word.box[3] - word.box[1]) * height * 0.9) + 'px';
    });
  });
};

WordTools.prototype.choose = function (page, words) {
  this.clearSelection();
  if (this.editor.mode !== 'select' || !words.length) { return; }
  this.selectedPage = page;
  this.selected = words;
  var map = page.wordMap;
  each(page.wordLayer, '.redaction-word', function (span) {
    var selected = words.indexOf(map.words[Number(span.getAttribute('data-word-index'))]) >= 0;
    span.classList.toggle('is-selected', selected);
    span.setAttribute('aria-pressed', String(selected));
  });
  this.selectButton.disabled = false;
  this.message(words.length + (words.length === 1 ? ' word selected.' : ' words selected.') + ' Check the coverage, then choose ' + selectionLabel(this.editor.form) + '.');
};

WordTools.prototype.nativeSelection = function () {
  if (this.editor.mode !== 'select') { return; }
  var selection = window.getSelection();
  if (!selection || selection.isCollapsed || !selection.rangeCount) { return; }
  var range = selection.getRangeAt(0);
  var page = this.editor.pages.filter(function (candidate) { return candidate.wordLayer && candidate.wordLayer.contains(range.startContainer); })[0];
  if (!page) { return; }
  if (!page.wordLayer.contains(range.endContainer)) {
    this.clearSelection(); this.message('Select text on one page at a time.'); return;
  }
  var words = [];
  each(page.wordLayer, '.redaction-word', function (span) {
    if (range.intersectsNode(span) && !(span.contains(range.endContainer) && range.endOffset === 0) &&
        !(span.contains(range.startContainer) && range.startOffset >= span.textContent.length) && span.textContent.trim()) { words.push(page.wordMap.words[Number(span.getAttribute('data-word-index'))]); }
  });
  this.choose(page, words);
};

WordTools.prototype.load = async function (page) {
  if (!page) { return; }
  if (!page.element.hasAttribute('data-words-url')) {
    this.stop();
    this.targetPage = page;
    this.clearSelection();
    this.message('This page has no text to select (it may be a scan or a picture). Use manual boxes.');
    return;
  }
  this.stop();
  this.targetPage = page;
  this.clearSelection();
  this.results.textContent = '';
  this.tools.querySelector('[data-word-results-wrap]').hidden = true;
  var generation = this.generation;
  this.dropMap(page);
  this.message('Reading visible words on page ' + page.number + '… Manual boxes remain available.');
  try {
    var map = await this.fetchPage(page, generation);
    if (generation !== this.generation) { return; }
    this.showMap(page, map);
    var messages = {
      ready: 'Select words on this page, then choose ' + selectionLabel(this.editor.form) + '. Check every box.',
      partial: 'Some words are hidden by site rules and cannot be selected here. Check the page manually.',
      masked: 'Site rules prevent showing the text of this page. Use manual boxes.',
      unavailable: 'This page has no text to select (it may be a scan or a picture). Use manual boxes.'
    };
    var pictured = map.pictures && (map.state === 'ready' || map.state === 'partial') ? ' This page also has a picture; anything written in the picture can’t be selected or found, so check it by eye.' : '';
    this.message(messages[map.state] + pictured);
  } catch (error) {
    if (generation !== this.generation) { return; }
    this.dropMap(page);
    if (error.message === 'stale' || error.message === 'invalid') {
      var tools = this;
      this.editor.pages.forEach(function (candidate) { tools.dropMap(candidate); });
    }
    this.message(error.message === 'stale' ? 'The file or access changed. Reload before using text selection.' : 'Text selection could not be loaded. Manual boxes remain available.');
  }
};

WordTools.prototype.coordinates = function (map, words) {
  var groups = [];
  words.forEach(function (word) {
    var group = groups[groups.length - 1];
    var previous = group && group[group.length - 1];
    if (!previous || previous.line !== word.line || map.words.indexOf(word) !== map.words.indexOf(previous) + 1 || word.box[0] - previous.box[2] > Math.max(0.02, (word.box[3] - word.box[1]) * 2)) {
      groups.push([word]);
    } else { group.push(word); }
  });
  return groups.map(function (group) {
    return [Math.min.apply(null, group.map(function (w) { return w.box[0]; })) - 0.002,
      Math.min.apply(null, group.map(function (w) { return w.box[1]; })) - 0.002,
      Math.max.apply(null, group.map(function (w) { return w.box[2]; })) + 0.002,
      Math.max.apply(null, group.map(function (w) { return w.box[3]; })) + 0.002].map(function (value) { return clamp(value, 0, 1); });
  });
};

WordTools.prototype.addBoxes = function (page, words, label) {
  if (!page || !words.length || this.editor.busy || !page.wordMap) { return; }
  var map = page.wordMap;
  if (!words.every(function (word) { return map.words.indexOf(word) >= 0; })) { this.message('Read this page again before redacting text.'); return; }
  return this.addCoordinates(page, this.coordinates(map, words), label);
};

WordTools.prototype.addCoordinates = function (page, coordinates, label) {
  if (!page || !coordinates.length || this.editor.busy) { return; }
  if (page.boxes.length + coordinates.length > 200) { this.message('Too many boxes on this page. Save this edit before adding more.'); return; }
  var boxes = coordinates.map(function (coords) { var box = new Box(page, coords); box.attach(); return box; });
  this.editor.history.record(label + ' on page ' + page.number,
    function () { boxes.forEach(function (box) { box.detach(); }); },
    function () { boxes.forEach(function (box) { box.attach(); }); },
    function () { boxes[0].focus(); });
  this.message('Added ' + boxes.length + (boxes.length === 1 ? ' box.' : ' boxes.') + ' Review the boxes, save, then check the generated file.');
  return boxes;
};

WordTools.prototype.find = async function () {
  if (this.editor.busy) { return; }
  var query = this.query.value.normalize('NFKC').toLowerCase().trim().replace(/\s+/g, ' ').slice(0, 100);
  if (!query) { this.message('Enter a word or phrase to find.'); return; }
  this.editor.setMode('draw');
  this.stop();
  var generation = this.generation;
  var tools = this;
  this.results.textContent = '';
  this.editor.pages.forEach(function (page) { tools.dropMap(page); });
  var wrapper = this.tools.querySelector('[data-word-results-wrap]');
  wrapper.hidden = false; wrapper.open = true;
  this.tools.querySelector('[data-word-stop]').disabled = false;
  var matches = 0;
  var missing = 0;
  var checked = 0;
  var pictured = 0;
  var pages = this.editor.pages.filter(function (page) { return page.element.hasAttribute('data-words-url'); });
  try {
    for (var p = 0; p < pages.length; p++) {
      var page = pages[p];
      this.dropMap(page);
      if (p === 0) { this.message('Finding visible text…'); }
      this.progress('Page ' + page.number + ' (' + (p + 1) + ' of ' + pages.length + ')…');
      var map = await this.fetchPage(page, generation);
      if (generation !== this.generation) { return; }
      // Find retains bounded data, not thousands of off-screen DOM nodes.
      page.wordMap = map;
      if (map.state !== 'ready') { missing += 1; }
      if (map.state === 'ready' && !map.pictures) { checked += 1; }
      if (map.pictures) { pictured += 1; }
      var text = '';
      var spans = map.words.map(function (word) {
        var start = text.length;
        text += word.text.normalize('NFKC').toLowerCase() + ' ';
        return { start: start, end: text.length - 1, word: word };
      });
      var at = 0;
      while ((at = text.indexOf(query, at)) >= 0 && matches < 100) {
        var words = spans.filter(function (span) { return span.end > at && span.start < at + query.length; }).map(function (span) { return span.word; });
        this.result(page, words);
        matches += 1; at += Math.max(query.length, 1);
      }
      if (matches >= 100) { break; }
    }
    var unchecked = this.editor.pages.length - checked;
    this.tools.querySelector('[data-word-results-summary]').textContent = matches + ' find results';
    this.message(matches + ' matches in the text of the file. ' + unchecked + ' pages were not fully searched (scans and pictures have no text to search; also limits or masked text). ' +
      (matches >= 100 ? 'Showing the first 100 matches. ' : '') + (missing ? 'Some text was unavailable. ' : '') +
      (pictured ? pictured + (pictured === 1 ? ' page has' : ' pages have') + ' a picture, which can’t be searched. ' : '') + 'Check every page; no matches does not mean no sensitive information.');
  } catch (error) {
    if (generation !== this.generation) { return; }
    if (error.message === 'stale' || error.message === 'invalid') {
      this.results.textContent = '';
      this.editor.pages.forEach(function (page) { tools.dropMap(page); });
    }
    this.message(error.message === 'stale' ? 'The file or access changed. Reload before finding or selecting text.' : 'Find could not finish. Remaining pages have not been checked; use manual boxes.');
  } finally {
    if (generation === this.generation) { this.tools.querySelector('[data-word-stop]').disabled = true; this.progress(''); }
  }
};

WordTools.prototype.result = function (page, words) {
  if (!words.length) { return; }
  var tools = this;
  var item = document.createElement('li');
  var show = document.createElement('button'); show.type = 'button';
  show.textContent = 'Page ' + page.number + ': ' + words.map(function (word) { return word.text; }).join(' ');
  show.addEventListener('click', function () {
    // Navigation must not start a second request while find is running.
    if (!page.wordMap || !words.every(function (word) { return page.wordMap.words.indexOf(word) >= 0; })) { tools.message('Find again to refresh this result.'); return; }
    tools.editor.goPage(page, true);
    if (!page.wordLayer) { tools.showMap(page, page.wordMap); }
    each(page.wordLayer, '.redaction-word', function (span) { span.classList.remove('is-found'); });
    words.forEach(function (word) {
      var span = page.wordLayer.children[page.wordMap.words.indexOf(word)];
      span.classList.add('is-found'); span.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    });
  });
  var redact = document.createElement('button'); redact.type = 'button';
  redact.textContent = (this.tools || redact).getAttribute('data-match-label') || 'Redact this match';
  redact.addEventListener('click', function () { tools.addBoxes(page, words, 'Redacted find match'); });
  item.appendChild(show); item.appendChild(redact); this.results.appendChild(item);
};
