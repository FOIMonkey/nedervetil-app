const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');
const { pathToFileURL } = require('node:url');

const helper = pathToFileURL(
  path.join(__dirname, '../../app/javascript/public/helpers/thread_gaps.js')
).href;

function gaps(dates, { daysBetween, gapText }) {
  const labels = [];
  for (let i = 1; i < dates.length; i++) {
    if (dates[i - 1] === null || dates[i] === null) { continue; }
    const days = daysBetween(dates[i - 1], dates[i]);
    if (days !== null) { labels.push(gapText(days)); }
  }
  return labels;
}

test('thread gaps', async (t) => {
  const helpers = await import(helper);

  for (const [name, earlier, later, expected] of [
    ['London midnight within one UTC day',
      '2026-07-01T23:30:00+01:00', '2026-07-02T00:30:00+01:00', '1 day later'],
    ['one London day across UTC midnight',
      '2026-07-01T00:30:00+01:00', '2026-07-01T23:30:00+01:00', 'Same day'],
    ['a date west of UTC',
      '2026-07-01T23:30:00-07:00', '2026-07-02T00:30:00-07:00', '1 day later'],
    ['spring clock change',
      '2026-03-29T00:30:00+00:00', '2026-03-30T00:30:00+01:00', '1 day later'],
    ['autumn clock change',
      '2026-10-25T00:30:00+01:00', '2026-10-26T00:30:00+00:00', '1 day later'],
    ['leap day', '2024-02-28', '2024-03-01', '2 days later'],
    ['year boundary', '2026-12-31', '2027-01-01', '1 day later'],
    ['years below 100', '0099-12-31', '0100-01-01', '1 day later'],
    ['multiple days', '2026-07-01T12:00:00Z', '2026-07-04T12:00:00Z', '3 days later']
  ]) {
    await t.test(name, () => {
      assert.deepEqual(gaps([earlier, later], helpers), [expected]);
    });
  }

  for (const value of [null, '', 'invalid', '2026-02-30', '2026-07-01Tinvalid']) {
    await t.test(`ignores a missing or invalid date: ${value}`, () => {
      assert.deepEqual(gaps([value, '2026-07-02T12:00:00Z'], helpers), []);
    });
  }
});
