import { percent } from "editor/geometry"
import { each, setText } from "editor/dom"
import { historyKey } from "editor/history"

// Session-only suggestions over freshly authorized, masked word maps. No
// profile values or user phrases are stored, submitted, or used as PDF text.
export function PersonalTools(words) {
  this.words = words;
  this.editor = words.editor;
  this.panel = words.form.querySelector('[data-personal-tools]');
  this.items = [];
  this.groups = [];
  this.running = false;
  if (!this.panel || !words.status || !this.editor.pages.some(function (page) { return page.element.hasAttribute('data-words-url'); })) { return; }
  var tools = this;
  this.panel.hidden = false;
  each(document, '[data-personal-mount]', function (mount) {
    if (words.form.id && mount.getAttribute('data-personal-mount') === words.form.id) { tools.home = [tools.panel.parentNode, tools.panel.nextSibling]; tools.mount = [mount, Array.from(mount.childNodes)]; mount.textContent = ''; mount.appendChild(tools.panel); }
  });
  this.plain = this.panel.hasAttribute('data-personal-plain');
  this.status = this.panel.querySelector('[data-personal-status]');
  this.statusText = this.status && this.status.textContent;
  this.progressLine = this.panel.querySelector('[data-personal-progress]');
  this.results = this.panel.querySelector('[data-personal-results]');
  this.phrase = this.panel.querySelector('[data-personal-phrase]');
  this.stopButton = this.panel.querySelector('[data-personal-stop]');
  this.panel.querySelector('[data-personal-scan]').addEventListener('click', function () { tools.scan(); }, { signal: tools.editor.signal });
  this.stopButton.addEventListener('click', function () {
    tools.words.stop(true); tools.running = false; tools.stopButton.disabled = true; setText(tools.progressLine, ''); if (tools.plain) { tools.stopButton.hidden = true; }
    tools.message('Suggestions stopped. Remaining pages have not been checked. You can review the results already shown.');
  }, { signal: tools.editor.signal });
  if (this.phrase) {
    this.phrase.addEventListener('input', function () { tools.words.stop(true); tools.invalidate('Phrase changed. Scan again to refresh suggestions.'); }, { signal: tools.editor.signal });
    this.phrase.addEventListener('keydown', function (event) { if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); tools.scan(); } }, { signal: tools.editor.signal });
  }
  this.panel.addEventListener('keydown', function (event) {
    if (!tools.editor.busy && !words.form.contains(event.target) && !event.target.closest('input, textarea, select, [contenteditable="true"]')) { historyKey(event, tools.editor.history); }
  }, { signal: tools.editor.signal });
}

PersonalTools.prototype.destroy = function () {
  if (this.results) { this.results.textContent = ''; }
  if (this.stopButton) { this.stopButton.disabled = true; this.stopButton.hidden = this.plain; }
  if (this.progressLine) { setText(this.progressLine, ''); }
  if (this.status) { this.status.textContent = this.statusText; }
  if (this.home) { this.home[0].insertBefore(this.panel, this.home[1]); }
  if (this.mount) { this.mount[0].replaceChildren.apply(this.mount[0], this.mount[1]); }
};

PersonalTools.prototype.message = function (text) { setText(this.status, text); };
PersonalTools.prototype.invalidate = function (message) {
  this.items = []; this.groups = []; this.running = false;
  if (this.results) { this.results.textContent = ''; }
  if (this.stopButton) { this.stopButton.disabled = true; }
  this.clearHighlights();
  this.message(message || (this.plain ? '' : 'Scan again to refresh personal-detail suggestions. Pending boxes are unchanged.'));
};
PersonalTools.prototype.normal = function (value) { return value.normalize('NFKC').toLowerCase().replace(/[’‘ʼ`´]/g, "'").replace(/\s+/g, ' ').trim(); };

PersonalTools.prototype.candidates = function (map, phrase) {
  var personal = map.personal;
  var available = personal && personal.state === 'ready';
  var kinds = ['email', 'name', 'surname', 'greeting', 'title'];
  var candidates = [];
  var hidden = [];
  if (personal) {
    if (['ready', 'unavailable'].indexOf(personal.state) < 0 || !Array.isArray(personal.items) || personal.items.length > 100 ||
        typeof personal.limited !== 'boolean' || typeof personal.name_consent !== 'boolean' || (!available && personal.items.length)) { throw new Error('invalid'); }
    var ids = new Map(map.words.map(function (word, index) { return [word.id, index]; }));
    var used = new Set();
    var areaCount = 0;
    personal.items.forEach(function (item) {
      if (item.areas) {
        areaCount += item.areas.length;
        if (item.words || !Array.isArray(item.areas) || !item.areas.length || areaCount > 5000 ||
            !item.areas.every(function (area) { return Array.isArray(area) && area.length === 4 && area.every(function (n) { return Number.isFinite(n) && n >= 0 && n <= 1; }) && area[2] > area[0] && area[3] > area[1]; }) ||
            typeof item.cross_line !== 'boolean' || !Array.isArray(item.kinds) || !item.kinds.length || item.kinds.length > 5 ||
            !item.kinds.every(function (kind) { return kinds.indexOf(kind) >= 0; })) { throw new Error('invalid'); }
        hidden.push(item); return;
      }
      if (!Array.isArray(item.words) || !item.words.length || item.words.length > 5000 || !Array.isArray(item.kinds) || !item.kinds.length || item.kinds.length > 5 ||
          !item.kinds.every(function (kind) { return kinds.indexOf(kind) >= 0; })) { throw new Error('invalid'); }
      var indices = item.words.map(function (id) {
        if (!ids.has(id) || used.has(id)) { throw new Error('invalid'); }
        used.add(id); return ids.get(id);
      });
      if (!indices.every(function (index, i) { return i === 0 || index === indices[i - 1] + 1; })) { throw new Error('invalid'); }
      candidates.push({ first: indices[0], last: indices[indices.length - 1], kinds: item.kinds });
    });
  }
  var limited = !!(personal && personal.limited);
  if (phrase) {
    var text = '';
    var tools = this;
    var spans = map.words.map(function (word, i) {
      text += i && Number(word.id) !== Number(map.words[i - 1].id) + 1 ? '\0' : ' ';
      var start = text.length; text += tools.normal(word.text);
      return { start: start, end: text.length };
    });
    var at = 0;
    var count = 0;
    while ((at = text.indexOf(phrase, at)) >= 0) {
      var before = Array.from(text.slice(0, at)).pop() || '';
      var after = Array.from(text.slice(at + phrase.length))[0] || '';
      if (!/[\p{L}\p{N}]/u.test(before) && !/[\p{L}\p{N}]/u.test(after)) {
        count += 1;
        if (count > 100) { limited = true; break; }
        var indices = [];
        spans.forEach(function (span, i) { if (span.end > at && span.start < at + phrase.length) { indices.push(i); } });
        if (indices.length) { candidates.push({ first: indices[0], last: indices[indices.length - 1], kinds: ['phrase'] }); }
      }
      at += Math.max(phrase.length, 1);
    }
  }
  var merged = [];
  candidates.sort(function (a, b) { return a.first - b.first || a.last - b.last; }).forEach(function (item) {
    var previous = merged[merged.length - 1];
    if (previous && item.first <= previous.last) {
      previous.last = Math.max(previous.last, item.last);
      item.kinds.forEach(function (kind) { if (previous.kinds.indexOf(kind) < 0) { previous.kinds.push(kind); } });
    } else { merged.push({ first: item.first, last: item.last, kinds: item.kinds.slice() }); }
  });
  return { items: merged.concat(hidden), available: available, limited: limited };
};

PersonalTools.prototype.scan = async function () {
  if (!this.status || this.editor.busy) { return; }
  this.editor.setMode('draw');
  this.words.stop(true);
  this.invalidate();
  this.panel.open = true;
  var generation = this.words.generation;
  var phrase = this.phrase ? this.normal(this.phrase.value).slice(0, 500) : '';
  var tools = this;
  this.editor.pages.forEach(function (page) { tools.words.dropMap(page); });
  this.running = true; this.stopButton.disabled = false; this.stopButton.hidden = false;
  var pages = this.editor.pages.filter(function (page) { return page.element.hasAttribute('data-words-url'); });
  var checked = 0;
  var limited = false;
  var pictured = 0;
  try {
    for (var p = 0; p < pages.length; p++) {
      var page = pages[p];
      if (p === 0) { this.message(this.plain ? 'Looking through the pages…' : 'Looking for personal details…'); }
      setText(this.progressLine, 'Page ' + page.number + ' (' + (p + 1) + ' of ' + pages.length + ')…');
      var map = await this.words.fetchPage(page, generation);
      if (generation !== this.words.generation) { return; }
      var found = this.candidates(map, phrase);
      if (map.state === 'ready' && found.available && !found.limited && !map.pictures) { checked += 1; }
      if (map.pictures) { pictured += 1; }
      limited = limited || found.limited;
      // Keep only bounded word data. Off-screen words get no overlay DOM.
      page.wordMap = map;
      var remaining = 100 - this.items.length;
      if (found.items.length > remaining) { limited = true; }
      this.addPage(page, map, found.items.slice(0, remaining));
      if (this.items.length >= 100) { limited = true; break; }
    }
    // Never "none found" about pages that have no text to search.
    var unsearched = this.editor.pages.length - pages.length;
    var unsearchedNote = (unsearched ? unsearched + (unsearched === 1 ? ' page has' : ' pages have') + ' no text to search (scans or pictures). ' : '') +
      (pictured ? pictured + (pictured === 1 ? ' page has' : ' pages have') + ' a picture, which can’t be searched. ' : '');
    if (this.plain) {
      this.message((this.items.length ? this.items.length + (this.items.length === 1 ? ' place to look at.' : ' places to look at.') : 'None found in the text.') + ' ' + unsearchedNote + 'Check every page too.');
    } else this.message(this.items.length + ' possible personal details. ' + (this.editor.pages.length - checked) +
      ' shown pages were not fully searched (including scans and pictures, masked text or limits). ' + (limited ? 'Showing at most 100 suggestions; more may remain. ' : '') + unsearchedNote +
      'Only pages shown here are searched. Check the whole file; no suggestions does not mean no sensitive information. Dismissing a suggestion does not approve publication.');
  } catch (error) {
    if (generation !== this.words.generation) { return; }
    if (error.message === 'stale' || error.message === 'invalid') {
      this.invalidate();
      this.editor.pages.forEach(function (page) { tools.words.dropMap(page); });
    }
    this.message(error.message === 'stale' ? 'The file or access changed. Reload before using suggestions.' : 'Suggestions could not finish. Remaining pages have not been checked. Use manual boxes.');
  } finally {
    setText(this.progressLine, '');
    if (generation === this.words.generation) { this.running = false; this.stopButton.disabled = true; if (this.plain) { this.stopButton.hidden = true; } this.refresh(); }
  }
};

PersonalTools.prototype.clearHighlights = function () {
  each(this.editor.form, '.redaction-word.is-found', function (span) { span.classList.remove('is-found'); });
  each(this.editor.form, '.redaction-suggestion-highlight', function (area) { area.remove(); });
};
PersonalTools.prototype.show = function (item) {
  if (this.items.indexOf(item) < 0) { return; }
  this.editor.setMode('draw');
  this.editor.goPage(item.page, true);
  this.clearHighlights();
  if (item.words.length) {
    if (item.page.wordMap !== item.map || !item.page.wordLayer) { this.words.showMap(item.page, item.map); }
    item.words.forEach(function (word) {
      var span = item.page.wordLayer.children[item.map.words.indexOf(word)];
      span.classList.add('is-found'); span.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    });
  } else {
    item.areas.forEach(function (box) {
      var area = document.createElement('span'); area.className = 'redaction-suggestion-highlight'; area.setAttribute('aria-hidden', 'true');
      area.style.left = percent(box[0]); area.style.top = percent(box[1]); area.style.width = percent(box[2] - box[0]); area.style.height = percent(box[3] - box[1]);
      item.page.sheet.appendChild(area); area.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    });
  }
};
PersonalTools.prototype.contains = function (outer, inner) {
  return outer[0] <= inner[0] + 0.000001 && outer[1] <= inner[1] + 0.000001 && outer[2] >= inner[2] - 0.000001 && outer[3] >= inner[3] - 0.000001;
};
PersonalTools.prototype.areaCovered = function (page, area) {
  var tools = this;
  return page.boxes.some(function (box) { return tools.contains(box.coords(), area); });
};
PersonalTools.prototype.covered = function (item) {
  var tools = this;
  return item.areas.every(function (area) { return tools.areaCovered(item.page, area); });
};
PersonalTools.prototype.add = function (items) {
  if (this.editor.busy || !items.length) { return; }
  var tools = this;
  var page = items[0].page;
  var map = items[0].map;
  if (!items.every(function (item) { return tools.items.indexOf(item) >= 0 && item.page === page && item.map === map; })) { return; }
  var areas = [];
  items.forEach(function (item) {
    if (!item.dismissed) {
      item.areas.forEach(function (area) {
        if (tools.areaCovered(page, area) || areas.some(function (existing) { return tools.contains(existing, area); })) { return; }
        areas = areas.filter(function (existing) { return !tools.contains(area, existing); });
        areas.push(area);
      });
    }
  });
  if (!areas.length) { return; }
  this.editor.setMode('draw');
  var boxes = this.words.addCoordinates(page, areas, 'Added personal-detail suggestions');
  if (boxes) { this.message('Added ' + boxes.length + ' pending boxes on page ' + page.number + '. Review them, save, then check the generated file.'); }
  else { this.message('No suggestion boxes were added. Check the page box limit and use manual editing.'); }
  this.refresh();
};
PersonalTools.prototype.addPage = function (page, map, matches) {
  if (!matches.length) { return; }
  var tools = this;
  var group = document.createElement('li'); group.className = 'redaction-personal__page';
  var heading = document.createElement('p'); heading.textContent = 'Page ' + page.number;
  var all = document.createElement('button'); all.type = 'button'; all.setAttribute('data-personal-add-page', page.number);
  var list = document.createElement('ol');
  var entries = matches.map(function (match) {
    var words = match.areas ? [] : map.words.slice(match.first, match.last + 1);
    var item = { page: page, map: map, words: words, areas: match.areas || tools.words.coordinates(map, words), dismissed: false };
    var row = document.createElement('li'); row.setAttribute('data-personal-occurrence', '');
    var show = document.createElement('button'); show.type = 'button'; show.setAttribute('data-personal-show', '');
    show.textContent = match.areas ? 'Show suggested area (text hidden by a site rule)' : words.map(function (word) { return word.text; }).join(' ');
    var label = document.createElement('p');
    label.textContent = match.kinds.map(function (kind) { return (tools.plain ? { email: 'Your email', name: 'Your name', surname: 'Your surname', greeting: 'Your first name', title: 'Your surname', phrase: 'What you typed' } : { email: 'Requester email', name: 'Requester name', surname: 'Requester surname', greeting: 'Requester first name in a greeting', title: 'Requester surname after a title', phrase: 'Your phrase' })[kind]; }).join(' · ');
    var caution = [];
    if (match.kinds.every(function (kind) { return kind === 'surname' || kind === 'title'; })) { caution.push('This may refer to someone else.'); }
    if (match.cross_line || words.some(function (word) { return word.line !== words[0].line; })) { caution.push('Match crosses lines; check the reading order and every box.'); }
    if (map.personal && map.personal.name_consent && match.kinds.indexOf('email') < 0 && match.kinds.indexOf('phrase') < 0) { caution.push('Name consent is recorded; removing this name is optional. Consent does not hide email suggestions.'); }
    var note = document.createElement('p'); note.textContent = caution.join(' ');
    var status = document.createElement('p'); status.setAttribute('data-personal-item-status', '');
    var add = document.createElement('button'); add.type = 'button'; add.textContent = 'Add box'; add.setAttribute('data-personal-add', '');
    var dismiss = document.createElement('button'); dismiss.type = 'button'; dismiss.textContent = 'Dismiss'; dismiss.setAttribute('data-personal-dismiss', '');
    show.addEventListener('click', function () { tools.show(item); });
    add.addEventListener('click', function () { tools.add([item]); });
    dismiss.addEventListener('click', function () {
      item.dismissed = !item.dismissed;
      tools.clearHighlights();
      tools.refresh(); tools.message(item.dismissed ? 'Dismissed for this session only. Check the page before publishing.' : 'Suggestion restored.');
    });
    row.appendChild(show); row.appendChild(label); if (caution.length) { row.appendChild(note); }
    row.appendChild(status); row.appendChild(add); row.appendChild(dismiss); list.appendChild(row);
    item.status = status; item.addButton = add; item.dismissButton = dismiss;
    tools.items.push(item); return item;
  });
  all.addEventListener('click', function () { tools.add(entries); });
  group.appendChild(heading); group.appendChild(all); group.appendChild(list); this.results.appendChild(group);
  this.groups.push({ page: page, items: entries, button: all }); this.refresh();
};
PersonalTools.prototype.refresh = function () {
  if (!this.status) { return; }
  var tools = this;
  this.items.forEach(function (item) {
    var covered = tools.covered(item);
    item.addButton.disabled = tools.editor.busy || item.dismissed || covered;
    item.dismissButton.textContent = item.dismissed ? 'Restore suggestion' : 'Dismiss';
    item.dismissButton.disabled = tools.editor.busy;
    item.status.textContent = covered ? 'Covered by pending boxes; save and check the generated file.' : item.dismissed ? 'Dismissed for this session.' : 'Not added.';
  });
  this.groups.forEach(function (group) {
    var count = group.items.filter(function (item) { return !item.dismissed && !tools.covered(item); }).length;
    group.button.textContent = 'Add ' + count + (count === 1 ? ' suggestion' : ' suggestions') + ' on page ' + group.page.number;
    group.button.disabled = tools.editor.busy || !count;
  });
};
