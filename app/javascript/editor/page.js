import { MIN, clamp } from "editor/geometry"
import { setText } from "editor/dom"
import { Box } from "editor/box"

export function Page(editor, element) {
  this.editor = editor;
  this.element = element;
  this.number = element.getAttribute('data-page');
  this.sheet = element.querySelector('[data-sheet]');
  this.count = element.querySelector('.redaction-page__count');
  this.addButton = element.querySelector('[data-add-box]');
  this.removeButton = element.querySelector('[data-remove-box]');
  this.clearButton = element.querySelector('[data-clear-page]');
  this.boxes = [];
  this.chosen = null;
  var page = this;
  this.addButton.addEventListener('click', function () { if (!editor.busy) { page.add().focus(); } }, { signal: editor.signal });
  this.clearButton.addEventListener('click', function () {
    if (editor.busy || !page.boxes.length) { return; }
    var boxes = page.boxes.map(function (box, index) { return { box: box, index: index, order: editor.order.indexOf(box) }; });
    function clear() { boxes.forEach(function (entry) { entry.box.detach(); }); }
    function restore() { boxes.forEach(function (entry) { entry.box.attach(entry.index, entry.order); }); }
    clear();
    editor.history.record('Cleared page ' + page.number, restore, clear, function () { page.addButton.focus(); });
    page.addButton.focus();
  }, { signal: editor.signal });
  if (this.removeButton) {
    this.removeButton.addEventListener('click', function () { if (page.chosen && !editor.busy) { page.chosen.remove(); page.addButton.focus(); } }, { signal: editor.signal });
  }
  this.sheet.addEventListener('pointerdown', function (event) { page.startDrawing(event); }, { signal: editor.signal });
  var image = element.querySelector('.redaction-page__image');
  if (image) {
    image.addEventListener('load', function () { page.unavailable = false; page.updateLabel(); if (editor.words) { editor.words.size(); } }, { signal: editor.signal });
    image.addEventListener('error', function () { page.unavailable = true; page.updateLabel(); }, { signal: editor.signal });
    // Modules load asynchronously, so an image may have already failed before listeners attach.
    if (image.complete && !image.naturalWidth) { this.unavailable = true; }
  }
}

Page.prototype.fraction = function (event) {
  var rect = this.sheet.getBoundingClientRect();
  return [clamp((event.clientX - rect.left) / rect.width, 0, 1), clamp((event.clientY - rect.top) / rect.height, 0, 1)];
};

Page.prototype.add = function (coords) {
  var box = new Box(this, coords || [0.3, 0.45, 0.7, 0.5]);
  box.attach();
  this.editor.history.record('Added box on page ' + this.number,
    function () { box.detach(); }, function () { box.attach(); }, function () { box.focus(); });
  return box;
};

Page.prototype.choose = function (box) {
  if (this.chosen) { this.chosen.element.classList.remove('is-chosen'); }
  this.chosen = box;
  if (box) { box.element.classList.add('is-chosen'); this.editor.navBox = box; }
  this.updateLabel();
  this.editor.updateBoxTools();
};

Page.prototype.startDrawing = function (event) {
  var editor = this.editor;
  if (editor.mode !== 'draw' || editor.busy || this.unavailable || event.button !== 0 || event.target.closest('.redaction-box')) { return; }
  event.preventDefault();
  var page = this;
  var start = this.fraction(event);
  var box = new Box(this, [start[0], start[1], start[0], start[1]]);
  this.sheet.appendChild(box.element);
  box.element.classList.add('is-drawing');
  editor.busy = true;
  editor.update();
  this.sheet.setPointerCapture(event.pointerId);
  function move(e) { var point = page.fraction(e); box.set([start[0], start[1], point[0], point[1]]); }
  function finish(keep) {
    page.sheet.removeEventListener('pointermove', move);
    page.sheet.removeEventListener('pointerup', end);
    page.sheet.removeEventListener('pointercancel', cancel);
    box.element.classList.remove('is-drawing');
    editor.busy = false;
    editor.cancelInteraction = null;
    if (keep && box.width() >= MIN && box.height() >= MIN) {
      box.attach();
      editor.history.record('Drew box on page ' + page.number,
        function () { box.detach(); }, function () { box.attach(); }, function () { box.focus(); });
      page.choose(box);
    } else { box.element.remove(); editor.update(); }
  }
  function end() { finish(true); }
  function cancel() { finish(false); }
  editor.cancelInteraction = cancel;
  this.sheet.addEventListener('pointermove', move);
  this.sheet.addEventListener('pointerup', end);
  this.sheet.addEventListener('pointercancel', cancel);
};

Page.prototype.updateLabel = function () {
  var n = this.boxes.length;
  setText(this.count, this.unavailable ? 'This page can’t be shown. Reload before editing.' :
    (n ? n + ' ' + (this.count.getAttribute('data-unit') || 'box') + (n === 1 ? '' : 'es') : (this.count.getAttribute('data-zero') || 'No boxes')));
  this.clearButton.hidden = !n;
  this.clearButton.disabled = this.editor.busy;
  this.addButton.disabled = this.editor.busy || this.unavailable;
  if (this.removeButton) { this.removeButton.hidden = !this.chosen; this.removeButton.disabled = this.editor.busy; }
  var page = this;
  this.boxes.forEach(function (box, index) { box.describe(index + 1, page.number); });
};
