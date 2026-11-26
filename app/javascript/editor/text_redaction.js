import { each, pending } from "editor/dom"
import { History, historyKey } from "editor/history"

export function TextRedaction(form) {
  var field = document.getElementById(form.getAttribute('data-text-redaction'));
  this.field = field;
  if (!field) { return; }
  this.listening = new AbortController();
  var signal = { signal: this.listening.signal };
  // Baseline is defaultValue so edits made before init or across reconnects stay dirty.
  var original = field.defaultValue;
  this.original = original;
  // Undo tracks from current value rather than defaultValue.
  var last = field.value;
  var phrases = [];
  this.phrases = phrases;
  var status = form.querySelector('[data-editor-status]');
  // The buttons can sit outside the form, so they are found by the field.
  each(document, '[data-redact-selection]', function (button) {
    if (button.getAttribute('data-redact-selection') !== field.id || typeof field.setRangeText !== 'function') { return; }
    button.hidden = false;
    button.addEventListener('click', function () {
      if (field.selectionStart !== field.selectionEnd) {
        field.setRangeText('[redacted]', field.selectionStart, field.selectionEnd, 'end');
        field.dispatchEvent(new Event('input', { bubbles: true }));
      }
      field.focus();
    }, signal);
  });
  function refresh() {
    pending(form, field.value !== original);
    phrases.forEach(function (phrase) {
      phrase.pattern.lastIndex = 0;
      var remains = phrase.pattern.test(field.value);
      phrase.button.disabled = !remains;
      phrase.button.textContent = remains ? phrase.label : (phrase.button.getAttribute('data-done-label') || 'Redacted');
    });
    each(form, '[data-undo-text]', function (button) { button.disabled = history.position === 0; });
    each(form, '[data-redo-text]', function (button) { button.disabled = history.position === history.actions.length; });
  }
  var history = new History(refresh, function (message) { if (status) { status.textContent = message; } });
  function restore(value) { field.value = last = value; }
  field.addEventListener('input', function () {
    var before = last;
    var after = field.value;
    if (before !== after) {
      last = after;
      history.record('Edited text', function () { restore(before); }, function () { restore(after); });
    } else { refresh(); }
  }, signal);
  each(document, '[data-redact-phrase]', function (button) {
    if (button.getAttribute('data-redact-field') && button.getAttribute('data-redact-field') !== field.id) { return; }
    var words = button.getAttribute('data-redact-phrase').trim().split(/\s+/).map(function (word) { return word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); });
    var pattern = new RegExp('(^|[^\\w])' + words.join('\\s+') + '(?![\\w])', 'gi');
    phrases.push({ button: button, pattern: pattern, label: button.textContent });
    button.addEventListener('click', function () {
      field.value = field.value.replace(pattern, '$1[redacted]');
      field.dispatchEvent(new Event('input', { bubbles: true }));
    }, signal);
  });
  each(form, '[data-undo-text]', function (button) { button.addEventListener('click', function () { history.step(false); }, signal); });
  each(form, '[data-redo-text]', function (button) { button.addEventListener('click', function () { history.step(true); }, signal); });
  form.addEventListener('keydown', function (event) {
    if (event.target === field || !event.target.closest('input, textarea, select, [contenteditable="true"]')) { historyKey(event, history); }
  }, signal);
  refresh();
}

TextRedaction.prototype.destroy = function () {
  if (!this.field) { return; }
  this.listening.abort();
  this.phrases.forEach(function (phrase) { phrase.button.textContent = phrase.label; phrase.button.disabled = false; });
};
