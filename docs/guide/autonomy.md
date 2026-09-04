# Turning autonomy up

Move one step at a time, and only after the previous step has been boring
for a while:

1. `mesthiri try` — nothing installed, nothing written.
2. Triage `(mode dry-run)` — reasoning in comments, no labels. What install
   gives you.
3. Triage `(mode live)` — labels applied.
4. Code `(mode live)` with `(max-tier 0)` — typo and docs fixes open real
   pull requests.
5. Code `(max-tier 1)` — ordinary bug fixes.
6. Review and fix `(mode live)`.

Tier 2 work — features, migrations, anything cross-cutting — always waits
for a human to authorize it, at every step. That authorization is
`/implement` from someone with write access — a human asking for that work
by name; there is deliberately no label for it and no configuration that
substitutes. And there is no step 7 in which mesthiri merges.
