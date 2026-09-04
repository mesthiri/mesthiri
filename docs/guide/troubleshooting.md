# When something goes wrong

Everything mesthiri does is a CI run, so the run log is the first place to
look, and each run uploads a JSONL trace as an artifact. The trace contains
the run record — stage, outcome, timings, spend, model, rubric SHA where
relevant — and retention follows CI artifact retention.

**A stage did nothing and said nothing.** The trigger did not match. Run
`mesthiri explain-event` against the run to see the normalized event and
which predicates were tested.

**Triage keeps proposing the wrong priority.** Read the rationale, not the
label. It usually cites the rubric clause it applied, which is either
being applied wrongly or is genuinely ambiguous — the second is more
common, and fixing your rubric fixes it everywhere.

**The code stage opened no pull request but commented on the issue.** It
could not reach green tests inside its budget. The comment says where it
got to. That is deliberate: a run that cannot finish reports its state
rather than opening a pull request that wastes your review.

**Authentication fails, or a stage cannot see the repository.** Almost
always a paste. The App IDs in `.mesthiri/config.scm` and the private keys
in your secrets have to be the same pair, and reader and writer are easy to
swap. `mesthiri whoami` mints a token from a key and prints which
installation it actually belongs to, what permissions it holds and the
remaining rate limit — run it and compare against the table in
[Installing](installing.md#register-the-two-apps).

**A run was refused for touching a denied path.** Working as intended, and
the comment names the rule and the file. If the path should be allowed,
that is an edit to `deny-paths` — which is itself on the deny list, so
mesthiri cannot make it.
