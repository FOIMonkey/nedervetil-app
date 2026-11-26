export function each(root, selector, fn) { Array.prototype.forEach.call(root.querySelectorAll(selector), fn); }

// Unchanged text isn't written, so a live region doesn't announce it again.
export function setText(element, text) { if (element && element.textContent !== text) { element.textContent = text; } }

export function selectionLabel(form) {
  var button = form.querySelector('[data-redact-words]');
  return button ? button.textContent.trim() : '';
}

export function pending(form, dirty) {
  var scope = form.closest('.publish-work') || form;
  each(scope, '[data-redaction-pending]', function (element) { element.hidden = !dirty; });
  each(scope, '[data-redaction-none]', function (element) { element.hidden = dirty; });
  each(scope, '[data-skip-finish]', function (link) { setText(link, link.getAttribute(dirty ? 'data-pending' : 'data-none')); });
}

// Height of a sticky/fixed overlay so redaction boxes stay clear of it.
export function coverOf(selector, form) {
  var scope = form.closest('.publish-work') || form;
  var element = scope.querySelector(selector);
  if (!element || !element.offsetHeight) { return 0; }
  var position = window.getComputedStyle(element).position;
  return position === 'sticky' || position === 'fixed' ? element.offsetHeight : 0;
}
