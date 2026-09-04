# Choosing models

Which model a stage uses is a property of the stage, not of the repository,
so it lives in that role's harness file. Triage reads issues and applies a
rubric; review argues with a diff. They do not need the same model, and
paying for the stronger one everywhere is the most common way to make this
expensive for no benefit.

You do not have to write these. mesthiri ships a harness for every role, and
a file under `.mesthiri/harness/` overrides whichever parts of it you name
and inherits the rest — so this is tuning, not setup. Budgets there may only
*lower* the per-run caps from `config.scm`; the repository-level number is a
ceiling, not a default to argue with.

```scheme
;; .mesthiri/harness/triage.scm
(harness
  (provider main)
  (model "claude-haiku-4-5-20251001")
  (effort low)
  (budgets (tokens 60000) (turns 12))
  (tools read grep)
  (prompt "..."))
```

```scheme
;; .mesthiri/harness/review.scm
(harness
  (provider main)
  (model "claude-opus-5")
  (effort high)
  (budgets (tokens 250000) (turns 30))
  (tools read grep test)
  (prompt "..."))
```

Name an exact model. A floating alias will be rejected rather than
resolved, and the reason is worth understanding: an alias that moves under
you changes every verdict and every review afterwards, with nothing in your
repository recording that anything changed. The model that produced a
result is written into the run record and into the `Generated-by` trailer of
any commit, so that six months from now a strange-looking pull request can
be traced to what actually wrote it.

**Review may not use the implementer's model.** If you declare two
providers, review must use the other one; with a single provider, review
must at least name a different model from the code harness, and a config
where the two match is rejected. This is not about mesthiri approving its
own work — it cannot, since findings are comments and no App can merge. It
is that a reviewer running the same model shares the implementer's blind
spots, which is precisely what you were hoping review would catch.

If you use a gateway or a self-hosted endpoint, point `endpoint` at it. The
sandbox allowlist follows from that value, so there is no second place to
update and no way for the two to disagree.

**Several providers, several keys.** Each provider names its own repository
secret, and the shim lists which to forward:

```yaml
  with:
    model-secrets: "ANTHROPIC_API_KEY DEEPSEEK_API_KEY"
  secrets: inherit
```

Only the names you list are exported. You need this as soon as two stages
must differ — mesthiri refuses a config where review runs the implementer's
provider and model, so review needs a model that code is not using, and on
some accounts that means a second provider entirely.

One thing not to assume from that: the allowlist is derived and reported,
and **not yet enforced**. The agent shares the runner's network. Its
containment is the filesystem and the absence of any repository credential,
which is what bounds what a compromised run can do to your repository — but
if you were counting on it being unable to reach the wider internet, it can.
