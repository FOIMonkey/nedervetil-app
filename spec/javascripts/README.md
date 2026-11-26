The thread gap tests run the date helpers the thread-timeline controller
uses (`app/javascript/public/helpers/thread_gaps.js`) with Node's built-in
test runner. They need Node 22 or later and no additional packages. Run
from the repository root:

```sh
TZ=America/Los_Angeles node spec/javascripts/thread_gaps_test.js
TZ=Pacific/Auckland node spec/javascripts/thread_gaps_test.js
```

Both runs must give the same labels: the site timezone in each rendered
timestamp determines its calendar date. These tests run separately from
RSpec; behaviour in the page is covered by the js: true specs in
spec/system.
