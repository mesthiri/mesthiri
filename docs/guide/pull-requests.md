# What a mesthiri pull request looks like

The agent writes the commits. It never pushes them — it has no credential
and no route to GitHub. The job reads the finished diff, checks it against
your deny-paths, and only then pushes:

```
Fix bounds check for empty vectors in vector-ref

The reader passes a legitimately empty vector; the bounds check treated
length 0 as an invalid index rather than an empty range. Adds a regression
test covering empty and single-element vectors.

Closes #412

Signed-off-by: Your Name <you@example.org>
Co-authored-by: mesthiri[bot] <...@users.noreply.github.com>
Generated-by: mesthiri 0.1.0; agent pi 0.84.4;
             model main/claude-opus-5; run .../actions/runs/1
```

The sign-off names **you**, and this is deliberate rather than a
formality. A DCO sign-off is a person certifying where a contribution came
from; a bot cannot do that, so mesthiri does not pretend otherwise. What
you are certifying is provenance and licence — that this is yours to offer
under the project's terms — not that you have read every line. Reading is
what the review stage and your merge are for, and the `Generated-by`
trailer is there so nobody mistakes one for the other.

Your CI runs on the pull request exactly as it would for a human
contributor. That run, not the agent's account of itself, is the evidence
the change is good.
