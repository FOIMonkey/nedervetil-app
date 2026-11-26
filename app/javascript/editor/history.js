// Undo and redo for the edits on the page that haven't been saved. Saved
// redactions are in the page itself and never in here.

export function History(refresh, announce) {
  this.actions = [];
  this.position = 0;
  this.refresh = refresh;
  this.announce = announce;
}

History.prototype.record = function (label, undo, redo, focus) {
  this.actions.splice(this.position);
  this.actions.push({ label: label, undo: undo, redo: redo, focus: focus });
  this.position += 1;
  this.refresh();
  this.announce(label);
};

History.prototype.step = function (redo) {
  if (redo ? this.position === this.actions.length : this.position === 0) { return; }
  var action = this.actions[redo ? this.position++ : --this.position];
  action[redo ? 'redo' : 'undo']();
  this.refresh();
  if (action.focus) { action.focus(); }
  this.announce((redo ? 'Redid: ' : 'Undid: ') + action.label);
};

// Ctrl or Command Z undoes; Y, or Shift and Z, redoes.
export function historyKey(event, history) {
  if (!(event.ctrlKey || event.metaKey) || event.altKey) { return; }
  var key = event.key.toLowerCase();
  if (key !== 'z' && key !== 'y') { return; }
  event.preventDefault();
  history.step(key === 'y' || event.shiftKey);
}
