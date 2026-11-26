// Prompts before leaving with unsaved editor changes; one page-wide guard covers all connected forms.

var unsaved = [];
var guarding = null;

export function UnsavedWork(form, boxEditor, textEditor) {
  this.form = form;
  this.boxEditor = boxEditor;
  this.textEditor = textEditor;
  this.note = form.elements.note;
  this.clean = JSON.stringify(this.boxEditor ? { boxes: {}, note: '' } : { text: this.textEditor.original, note: '' });
  // Rendered again after a failed save, the page starts with unsaved edits.
  this.initialDirty = form.getAttribute('data-unsaved-on-load') === 'true';
  this.submitting = false; this.allowLeaveUntil = 0;
  this.listening = new AbortController();
  var work = this;
  form.addEventListener('submit', function (event) {
    if (!event.defaultPrevented && !work.busy()) {
      work.submitting = true; work.submissionEvent = event;
      window.setTimeout(function () { if (event.defaultPrevented) { work.submitting = false; } }, 0);
    }
  }, { signal: this.listening.signal });
  unsaved.push(this);
  if (!guarding) { guarding = protectUnfinishedWork(); }
}
UnsavedWork.prototype.read = function () {
  var note = this.note ? this.note.value : '';
  if (this.boxEditor) {
    var boxes = {};
    this.boxEditor.pages.forEach(function (page) { if (page.boxes.length) { boxes[page.number] = page.boxes.map(function (box) { return box.coords(); }); } });
    return { boxes: boxes, note: note };
  }
  return { text: this.textEditor.field.value, note: note };
};
UnsavedWork.prototype.dirty = function () { return this.initialDirty || JSON.stringify(this.read()) !== this.clean; };
UnsavedWork.prototype.isSubmitting = function () { return this.submitting && !(this.submissionEvent && this.submissionEvent.defaultPrevented); };
UnsavedWork.prototype.busy = function () { return this.boxEditor && this.boxEditor.busy; };
UnsavedWork.prototype.destroy = function () {
  this.listening.abort();
  unsaved.splice(unsaved.indexOf(this), 1);
  if (!unsaved.length && guarding) { guarding.abort(); guarding = null; }
};

function protectUnfinishedWork() {
  var guard = new AbortController();
  var signal = guard.signal;
  function unfinished() { return unsaved.filter(function (work) { return work.dirty() && !work.isSubmitting(); }); }
  window.addEventListener('beforeunload', function (event) {
    if (unfinished().some(function (work) { return !work.allowLeaveUntil || work.allowLeaveUntil < Date.now(); })) {
      event.preventDefault(); event.returnValue = '';
    }
  }, { signal: signal });
  document.addEventListener('click', function (event) {
    var link = event.target.closest('a[href]');
    if (!link || event.defaultPrevented || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || link.target === '_blank' || link.hasAttribute('download')) { return; }
    var url = new URL(link.href, window.location.href);
    if (['http:', 'https:'].indexOf(url.protocol) < 0 || (url.pathname === window.location.pathname && url.search === window.location.search && (url.hash || link.getAttribute('href') === '#'))) { return; }
    var dirty = unfinished();
    if (dirty.length && !window.confirm('Leave with unfinished edits? They have not been applied.')) { event.preventDefault(); return; }
    dirty.forEach(function (work) { work.allowLeaveUntil = Date.now() + 1500; });
  }, { capture: true, signal: signal });
  document.addEventListener('submit', function (event) {
    var dirty = unfinished().filter(function (work) { return work.form !== event.target; });
    if (dirty.length && !window.confirm('Continue with unfinished edits on this page? They have not been applied.')) { event.preventDefault(); }
    else { dirty.forEach(function (work) { work.allowLeaveUntil = Date.now() + 1500; }); }
  }, { capture: true, signal: signal });
  window.addEventListener('pageshow', function () { unsaved.forEach(function (work) { work.submitting = false; work.allowLeaveUntil = 0; }); }, { signal: signal });
  return guard;
}
