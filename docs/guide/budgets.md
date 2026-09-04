# About budgets

Per-run caps are exact. A run counts its own tokens, turns and wall-clock
time and stops itself.

The per-day cap is not exact. mesthiri keeps no database, so before an
expensive stage a job looks at recent run history and declines if the day
already looks spent. The cap counts runs started, and schedules are
whole-hour UTC. That lags, and two jobs starting at the same moment
can both decide there is room. It is a runaway stop, not an accounting
system. If you need a hard ceiling, set one on your CI spending, where it
can actually be enforced.
