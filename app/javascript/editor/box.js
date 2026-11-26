// A box not yet saved, on a page: drawn, placed with a key or a button,
// moved, sized and removed. Its corners are fractions of the page.
import { MIN, STEP, BIG_STEP, clamp, percent, same } from "editor/geometry"
import { coverOf } from "editor/dom"

export function Box(page, coords) {
  this.page = page;
  this.id = 'pending-' + (++page.editor.nextId);
  this.element = document.createElement('button');
  this.element.type = 'button';
  this.element.className = 'redaction-box';
  this.element.setAttribute('data-box-id', this.id);
  this.element.setAttribute('aria-describedby', 'redaction-help');
  this.set(coords);
  var box = this;
  this.element.addEventListener('keydown', function (event) { box.key(event); });
  this.element.addEventListener('pointerdown', function (event) { box.startMoving(event); });
  this.element.addEventListener('focus', function () { if (page.boxes.indexOf(box) >= 0) { page.choose(box); } });
}

Box.prototype.attach = function (index, order) {
  if (this.page.boxes.indexOf(this) >= 0) { return; }
  this.page.boxes.splice(index === undefined ? this.page.boxes.length : index, 0, this);
  var list = this.page.editor.order;
  list.splice(order === undefined ? list.length : order, 0, this);
  var next = this.page.boxes[this.page.boxes.indexOf(this) + 1];
  this.page.sheet.insertBefore(this.element, next ? next.element : null);
};

Box.prototype.detach = function () {
  var page = this.page;
  var index = page.boxes.indexOf(this);
  if (index >= 0) { page.boxes.splice(index, 1); }
  index = page.editor.order.indexOf(this);
  if (index >= 0) { page.editor.order.splice(index, 1); }
  if (page.chosen === this) { page.choose(null); }
  this.element.remove();
};

Box.prototype.focus = function () {
  var target = this.page.boxes.indexOf(this) >= 0 ? this.element : this.page.addButton;
  target.focus({ preventScroll: true });
  this.reveal(target);
};

Box.prototype.reveal = function (target) {
  var element = target || this.element;
  var form = this.page.editor.form;
  element.style.scrollMarginTop = coverOf('.redaction-editor__tools', form) + 8 + 'px';
  element.style.scrollMarginBottom = Math.max(coverOf('.redaction-editor__submit', form), coverOf('.publish-save__go', form)) + 8 + 'px';
  element.scrollIntoView({ block: 'nearest', inline: 'nearest' });
};

Box.prototype.set = function (coords) {
  this.x0 = clamp(Math.min(coords[0], coords[2]), 0, 1);
  this.y0 = clamp(Math.min(coords[1], coords[3]), 0, 1);
  this.x1 = clamp(Math.max(coords[0], coords[2]), 0, 1);
  this.y1 = clamp(Math.max(coords[1], coords[3]), 0, 1);
  var style = this.element.style;
  style.left = percent(this.x0);
  style.top = percent(this.y0);
  style.width = percent(this.x1 - this.x0);
  style.height = percent(this.y1 - this.y0);
};
Box.prototype.width = function () { return this.x1 - this.x0; };
Box.prototype.height = function () { return this.y1 - this.y0; };
Box.prototype.coords = function () { return [this.x0, this.y0, this.x1, this.y1].map(function (v) { return Math.round(v * 1e6) / 1e6; }); };
Box.prototype.describe = function (index, number) {
  this.element.setAttribute('aria-label', 'Box ' + index + ' on page ' + number + ': ' + percent(this.x0) + ' across, ' + percent(this.y0) + ' down, ' + percent(this.width()) + ' wide, ' + percent(this.height()) + ' high');
};
Box.prototype.moveBy = function (dx, dy) {
  dx = clamp(dx, -this.x0, 1 - this.x1);
  dy = clamp(dy, -this.y0, 1 - this.y1);
  this.set([this.x0 + dx, this.y0 + dy, this.x1 + dx, this.y1 + dy]);
};
Box.prototype.resizeBy = function (dw, dh) {
  this.set([this.x0, this.y0, clamp(this.x1 + dw, this.x0 + MIN, 1), clamp(this.y1 + dh, this.y0 + MIN, 1)]);
};
Box.prototype.recordMove = function (before, label) {
  var after = this.coords();
  if (same(before, after)) { this.page.editor.update(); return; }
  var box = this;
  this.page.editor.history.record(label + ' on page ' + this.page.number,
    function () { box.set(before); }, function () { box.set(after); }, function () { box.focus(); });
};
Box.prototype.adjust = function (size, dx, dy) {
  var before = this.coords();
  this[size ? 'resizeBy' : 'moveBy'](dx, dy);
  this.recordMove(before, size ? 'Resized box' : 'Moved box');
  this.page.updateLabel();
  this.reveal();
};
Box.prototype.key = function (event) {
  if (this.page.editor.busy || event.ctrlKey || event.metaKey) { return; }
  var step = event.shiftKey ? BIG_STEP : STEP;
  var moves = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
  if (moves[event.key]) {
    event.preventDefault();
    this.adjust(event.altKey, moves[event.key][0], moves[event.key][1]);
  } else if (event.key === 'Delete' || event.key === 'Backspace') {
    event.preventDefault(); this.remove(); this.page.addButton.focus();
  }
};
Box.prototype.startMoving = function (event) {
  var editor = this.page.editor;
  if (editor.mode !== 'draw' || editor.busy || event.button !== 0) { return; }
  event.preventDefault(); event.stopPropagation(); this.element.focus();
  var box = this;
  var before = this.coords();
  var last = this.page.fraction(event);
  editor.busy = true; editor.update();
  this.element.setPointerCapture(event.pointerId);
  function move(e) {
    var point = box.page.fraction(e);
    box.moveBy(point[0] - last[0], point[1] - last[1]); last = point;
  }
  function finish(cancelled) {
    box.element.removeEventListener('pointermove', move);
    box.element.removeEventListener('pointerup', end);
    box.element.removeEventListener('pointercancel', cancel);
    editor.busy = false;
    editor.cancelInteraction = null;
    if (cancelled) { box.set(before); editor.update(); } else { box.recordMove(before, 'Moved box'); }
  }
  function end() { finish(false); }
  function cancel() { finish(true); }
  editor.cancelInteraction = cancel;
  this.element.addEventListener('pointermove', move);
  this.element.addEventListener('pointerup', end);
  this.element.addEventListener('pointercancel', cancel);
};
Box.prototype.remove = function () {
  if (this.page.editor.busy) { return; }
  var box = this;
  var index = this.page.boxes.indexOf(this);
  var order = this.page.editor.order.indexOf(this);
  this.detach();
  this.page.editor.history.record('Removed box on page ' + this.page.number,
    function () { box.attach(index, order); }, function () { box.detach(); }, function () { box.focus(); });
};
