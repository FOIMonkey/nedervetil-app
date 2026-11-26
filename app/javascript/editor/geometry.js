// Boxes and words are placed in fractions of a page, 0 to 1 from the top
// left, so zoom and window size never change what is submitted.

// The smallest box, and how far a key or button moves or sizes one.
export const MIN = 0.004
export const STEP = 0.005
export const BIG_STEP = 0.05
export const BUTTON_STEP = 0.025

export function clamp(value, low, high) { return Math.min(Math.max(value, low), high); }
export function percent(value) { return Math.round(value * 1000000) / 10000 + '%'; }
export function same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
