// History holds unsaved edits only (saved redactions are baked into page images).
// Zoom, pan, and page navigation never alter submitted normalized coordinates.
import { BUTTON_STEP, clamp } from "editor/geometry"
import { each, pending, selectionLabel, setText } from "editor/dom"
import { History, historyKey } from "editor/history"
import { Page } from "editor/page"
import { Box } from "editor/box"
import { WordTools } from "editor/word_tools"
import { PersonalTools } from "editor/personal_tools"

export function Editor(form) {
  this.form = form;
  this.listening = new AbortController();
  this.signal = this.listening.signal;
  this.field = form.querySelector('#redaction-boxes');
  this.total = form.querySelector('[data-total]');
  this.note = form.elements.note;
  this.status = form.querySelector('[data-editor-status]');
  this.pages = [];
  this.order = [];
  this.nextId = 0;
  this.zoom = 1;
  this.mode = 'draw';
  this.busy = false;
  this.list = document.getElementById(form.getAttribute('data-box-list') || '');
  var editor = this;
  this.history = new History(function () { editor.update(); }, function (message) { editor.say(message); });
  each(form, '.redaction-page', function (element) { editor.pages.push(new Page(editor, element)); });
  var initial = {};
  try { initial = JSON.parse(this.field.value || '{}') || {}; } catch (error) { initial = {}; }
  this.pages.forEach(function (page) {
    (initial[page.number] || []).forEach(function (coords) { new Box(page, coords).attach(); });
  });
  var pages = form.querySelector('.redaction-editor__pages');
  this.viewport = document.createElement('div');
  this.viewport.className = 'redaction-editor__viewport';
  this.viewport.tabIndex = 0;
  this.viewport.setAttribute('role', 'region');
  this.viewport.setAttribute('aria-label', 'Document pages; use arrow keys to scroll');
  pages.parentNode.insertBefore(this.viewport, pages);
  this.viewport.appendChild(pages);
  this.bindTools();
  this.viewport.addEventListener('scroll', function () { editor.updateNavigation(); }, { passive: true });
  this.viewport.addEventListener('pointerdown', function (event) { editor.pan(event); });
  form.addEventListener('keydown', function (event) {
    if (!editor.busy && !event.target.closest('input, textarea, select, [contenteditable="true"]')) {
      historyKey(event, editor.history);
    }
  }, { signal: editor.signal });
  // A half-finished pointer operation is never submitted.
  form.addEventListener('submit', function (event) { if (editor.busy) { event.preventDefault(); } }, { signal: editor.signal });
  this.form.classList.add('is-ready');
  if (window.ResizeObserver) {
    this.resizeObserver = new ResizeObserver(function () { editor.sizePages(); });
    this.resizeObserver.observe(this.viewport);
  } else {
    window.addEventListener('resize', function () { editor.sizePages(); }, { signal: editor.signal });
  }
  this.sizePages();
  this.update();
  this.words = new WordTools(this);
  this.personal = new PersonalTools(this.words);
  this.words.personal = this.personal;
}

Editor.prototype.say = function (message) { if (this.status) { this.status.textContent = message; } };

// Restores server DOM except #redaction-boxes so unsaved boxes survive reconnect.
Editor.prototype.destroy = function () {
  if (this.cancelInteraction) { this.cancelInteraction(); }
  this.listening.abort();
  if (this.resizeObserver) { this.resizeObserver.disconnect(); }
  this.words.destroy();
  this.personal.destroy();
  each(this.form, '.redaction-box, .redaction-word-layer, .redaction-suggestion-highlight', function (element) { element.remove(); });
  if (this.pageSelect) { this.pageSelect.textContent = ''; }
  if (this.list) { this.list.textContent = ''; }
  this.viewport.replaceWith(this.viewport.firstElementChild);
  this.form.classList.remove('is-ready', 'is-panning', 'is-selecting');
  each(this.form, '[data-mode-draw], [data-mode-pan], [data-mode-select]', function (button) {
    button.setAttribute('aria-pressed', String(button.hasAttribute('data-mode-draw')));
  });
};

Editor.prototype.bindTools = function () {
  var editor = this;
  function bind(selector, fn) {
    each(editor.form, selector, function (button) {
      button.addEventListener('click', function () { if (!editor.busy) { fn(); } }, { signal: editor.signal });
    });
  }
  bind('[data-undo]', function () { editor.history.step(false); });
  bind('[data-redo]', function () { editor.history.step(true); });
  bind('[data-add-box-here]', function () { var page = editor.currentPage(); if (page && !page.unavailable) { page.add().focus(); } });
  bind('[data-mode-draw]', function () { editor.setMode('draw'); });
  bind('[data-mode-pan]', function () { editor.setMode('pan'); });
  bind('[data-zoom-in]', function () { editor.setZoom(editor.zoom + 0.25); });
  bind('[data-zoom-out]', function () { editor.setZoom(editor.zoom - 0.25); });
  bind('[data-zoom-fit]', function () { editor.setZoom(1); editor.viewport.scrollLeft = 0; });
  bind('[data-page-prev]', function () { editor.pageStep(-1); });
  bind('[data-page-next]', function () { editor.pageStep(1); });
  bind('[data-box-prev]', function () { editor.boxStep(-1); });
  bind('[data-box-next]', function () { editor.boxStep(1); });
  each(this.form, '[data-box-move], [data-box-size]', function (button) {
    var size = button.hasAttribute('data-box-size');
    var way = button.getAttribute(size ? 'data-box-size' : 'data-box-move').split(',').map(Number);
    button.addEventListener('click', function () {
      var box = editor.chosenBox();
      if (box && !editor.busy) { box.adjust(size, way[0] * BUTTON_STEP, way[1] * BUTTON_STEP); editor.say(box.element.getAttribute('aria-label')); }
    }, { signal: editor.signal });
  });
  this.pageSelect = this.form.querySelector('[data-page-jump]');
  if (this.pageSelect) {
    this.pages.forEach(function (page) {
      var option = document.createElement('option');
      option.value = page.number;
      option.textContent = 'Page ' + page.number;
      editor.pageSelect.appendChild(option);
    });
    this.pageSelect.addEventListener('change', function () {
      if (editor.busy) { return; }
      var page = editor.pages.filter(function (candidate) { return candidate.number === editor.pageSelect.value; })[0];
      editor.goPage(page);
    }, { signal: editor.signal });
  }
};

Editor.prototype.currentPage = function () {
  if (this.viewport.scrollHeight > this.viewport.clientHeight + 2 &&
      this.viewport.scrollTop + this.viewport.clientHeight >= this.viewport.scrollHeight - 2) {
    return this.pages[this.pages.length - 1];
  }
  var top = this.viewport.getBoundingClientRect().top;
  return this.pages.filter(function (page) { return page.element.getBoundingClientRect().bottom > top + 10; })[0] || this.pages[this.pages.length - 1];
};

Editor.prototype.goPage = function (page, skipWords) {
  if (!page) { return; }
  this.viewport.scrollTop += page.element.getBoundingClientRect().top - this.viewport.getBoundingClientRect().top;
  this.updateNavigation();
  if (this.words && this.mode === 'select' && !skipWords) { this.words.load(page); }
  this.say('Page ' + page.number);
};

Editor.prototype.pageStep = function (direction) {
  this.goPage(this.pages[this.pages.indexOf(this.currentPage()) + direction]);
};

Editor.prototype.boxStep = function (direction) {
  var boxes = [];
  this.pages.forEach(function (page) { boxes = boxes.concat(page.boxes); });
  if (!boxes.length) { return; }
  var index = boxes.indexOf(this.navBox);
  index = index < 0 ? (direction > 0 ? 0 : boxes.length - 1) : (index + direction + boxes.length) % boxes.length;
  this.navBox = boxes[index];
  this.goPage(this.navBox.page);
  this.navBox.focus();
  this.say('Pending box ' + (index + 1) + ' of ' + boxes.length + ', page ' + this.navBox.page.number);
};

Editor.prototype.chosenBox = function () {
  var box = this.navBox;
  return box && box.page.chosen === box ? box : null;
};

// Compensate scroll so toggling box tools doesn't shift the viewport under the pointer.
Editor.prototype.updateBoxTools = function () {
  var tools = this.form.querySelector('[data-box-tools]');
  if (!tools || !this.viewport) { return; }
  var editor = this;
  var top = this.viewport.getBoundingClientRect().top;
  tools.hidden = !this.chosenBox();
  window.scrollBy(0, this.viewport.getBoundingClientRect().top - top);
  each(tools, 'button', function (button) { button.disabled = editor.busy; });
};

Editor.prototype.updateNavigation = function () {
  var current = this.currentPage();
  if (!current) { return; }
  if (this.pageSelect) { this.pageSelect.value = current.number; }
  var index = this.pages.indexOf(current);
  var editor = this;
  each(this.form, '[data-page-prev]', function (button) { button.disabled = editor.busy || index === 0; });
  each(this.form, '[data-page-next]', function (button) { button.disabled = editor.busy || index === editor.pages.length - 1; });
};

Editor.prototype.setMode = function (mode) {
  this.mode = mode;
  this.form.classList.toggle('is-panning', mode === 'pan');
  this.form.classList.toggle('is-selecting', mode === 'select');
  each(this.form, '[data-mode-select]', function (button) { button.setAttribute('aria-pressed', String(mode === 'select')); });
  if (this.words) {
    this.words.clearSelection();
    if (mode === 'select') { this.words.load(this.currentPage()); }
  }
  each(this.form, '[data-mode-draw]', function (button) { button.setAttribute('aria-pressed', String(mode === 'draw')); });
  each(this.form, '[data-mode-pan]', function (button) { button.setAttribute('aria-pressed', String(mode === 'pan')); });
  each(this.form, '.redaction-word-layer', function (layer) {
    layer.setAttribute('aria-hidden', String(mode !== 'select'));
    each(layer, '.redaction-word', function (span) { span.tabIndex = mode === 'select' && span === layer.firstElementChild ? 0 : -1; });
  });
  this.say(mode === 'pan' ? 'Pan mode. Drag to scroll; boxes stay in place.' : (mode === 'select' ? 'Select text on one page, then choose ' + selectionLabel(this.form) + '.' : 'Draw mode. Drag to add a box.'));
};

Editor.prototype.sizePages = function () {
  var baseWidth = Math.max(1, this.viewport.clientWidth - 2);
  if (this.baseWidth && this.baseWidth !== baseWidth && this.cancelInteraction) { this.cancelInteraction(); }
  this.baseWidth = baseWidth;
  var width = baseWidth * this.zoom;
  this.pages.forEach(function (page) { page.sheet.style.width = width + 'px'; });
  if (this.words) { this.words.size(); }
};

Editor.prototype.setZoom = function (zoom) {
  var page = this.currentPage();
  var viewport = this.viewport.getBoundingClientRect();
  var before = page && page.sheet.getBoundingClientRect();
  var cx = viewport.left + viewport.width / 2;
  var cy = viewport.top + viewport.height / 2;
  var fx = before && before.width ? (cx - before.left) / before.width : 0;
  var fy = before && before.height ? (cy - before.top) / before.height : 0;
  this.zoom = clamp(zoom, 0.5, 3);
  this.sizePages();
  if (before) {
    var after = page.sheet.getBoundingClientRect();
    this.viewport.scrollLeft += after.left + fx * after.width - cx;
    this.viewport.scrollTop += after.top + fy * after.height - cy;
  }
  this.update();
  this.say('Zoom ' + Math.round(this.zoom * 100) + ' percent');
};

Editor.prototype.pan = function (event) {
  if (this.mode !== 'pan' || event.button !== 0 || !event.target.closest('[data-sheet]') || this.busy) { return; }
  event.preventDefault();
  var editor = this;
  var start = [event.clientX, event.clientY, this.viewport.scrollLeft, this.viewport.scrollTop];
  this.busy = true;
  this.update();
  this.viewport.setPointerCapture(event.pointerId);
  function move(e) {
    editor.viewport.scrollLeft = start[2] + start[0] - e.clientX;
    editor.viewport.scrollTop = start[3] + start[1] - e.clientY;
  }
  function end() {
    editor.viewport.removeEventListener('pointermove', move);
    editor.viewport.removeEventListener('pointerup', end);
    editor.viewport.removeEventListener('pointercancel', end);
    editor.busy = false;
    editor.cancelInteraction = null;
    editor.update();
  }
  editor.cancelInteraction = end;
  this.viewport.addEventListener('pointermove', move);
  this.viewport.addEventListener('pointerup', end);
  this.viewport.addEventListener('pointercancel', end);
};

Editor.prototype.listBoxes = function () {
  if (!this.list) { return; }
  this.list.textContent = '';
  var editor = this;
  this.order.forEach(function (box) {
    var item = document.createElement('li');
    var what = document.createElement('span');
    what.className = 'publish-list__what';
    var name = 'box ' + (box.page.boxes.indexOf(box) + 1) + ' on page ' + box.page.number;
    what.textContent = name.charAt(0).toUpperCase() + name.slice(1);
    var meta = document.createElement('span');
    meta.className = 'publish-list__meta';
    meta.textContent = 'By you, not saved';
    var remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'publish-list__remove';
    remove.textContent = 'Remove';
    var which = document.createElement('span');
    which.className = 'visually-hidden';
    which.textContent = ': ' + name;
    remove.appendChild(which);
    remove.disabled = editor.busy;
    remove.addEventListener('click', function () { box.remove(); box.page.addButton.focus(); });
    item.appendChild(what);
    item.appendChild(meta);
    item.appendChild(remove);
    editor.list.appendChild(item);
  });
};

Editor.prototype.update = function () {
  if (this.personal) { this.personal.refresh(); }
  var data = {};
  this.pages.forEach(function (page) {
    var boxes = page.boxes.map(function (box) { return box.coords(); });
    if (boxes.length) { data[page.number] = boxes; }
    page.updateLabel();
  });
  this.field.value = JSON.stringify(data);
  setText(this.total, this.order.length ? this.order.length + (this.order.length === 1 ? ' box' : ' boxes') + ' in total.' : 'No boxes yet.');
  this.listBoxes();
  pending(this.form, this.order.length > 0);
  var editor = this;
  each(this.form, '[data-undo]', function (button) { button.disabled = editor.busy || editor.history.position === 0; });
  each(this.form, '[data-redo]', function (button) { button.disabled = editor.busy || editor.history.position === editor.history.actions.length; });
  each(this.form, '[data-box-prev], [data-box-next]', function (button) { button.disabled = editor.busy || !editor.order.length; });
  each(this.form, '[data-zoom-in]', function (button) { button.disabled = editor.busy || editor.zoom >= 3; });
  each(this.form, '[data-zoom-out]', function (button) { button.disabled = editor.busy || editor.zoom <= 0.5; });
  each(this.form, '[data-zoom-level]', function (output) { output.textContent = Math.round(editor.zoom * 100) + '%'; });
  this.updateNavigation();
  this.updateBoxTools();
};
