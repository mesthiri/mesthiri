# Your first triage

With `(mode dry-run)`, triage comments its reasoning and changes nothing:

> **mesthiri** commented on #412
>
> **Proposed: `priority: high`** — not applied, this repository is in
> dry-run.
>
> I reproduced this against `8c697da` before trusting the report. The
> issue attributes the crash to the reader, but the failure is in
> `vector-ref`'s bounds check one frame further in; the reader is passing
> a legitimately empty vector. Rubric §2 puts a reproducible crash in
> library code at `high`.
>
> **Intent tier 1** — a single issue is sufficient authorization to fix
> this.
>
> <sub>Rubric `docs/dev/github-issues.md` at `8c697da` · pi 0.84.4 ·
> 38k tokens · [run](https://github.com/owner/repo/actions/runs/1)</sub>

Leave it in dry-run for a week or two. Read the rationales rather than the
labels: a wrong label is a rubric problem you can fix, and a rationale
that reasons badly is a reason not to promote it yet. When you are
satisfied, change `(mode dry-run)` to `(mode live)`.
