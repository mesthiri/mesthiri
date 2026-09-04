# pi's RPC protocol, as observed

Status: recorded 2026-09-04 against **pi 0.84.4**, by driving it and reading
what came back. This is M0's recon, and `lib/mesthiri/agent.sld` (M3) is
written against this rather than against an assumption.

Everything here was captured from a live process. Where a claim is inferred
rather than observed, it says so.

## The flag is `--mode rpc`, not `--rpc`

Every mesthiri document said `pi --rpc` before this recon. There is no such
flag. The invocation is:

```
pi --mode rpc [--no-tools] [--no-session] [--model ...] [--thinking ...]
```

`--mode` takes `text` (default), `json` or `rpc`. Getting this wrong is not a
subtle failure — pi treats `--rpc` as an unknown option and exits — but it is
exactly the sort of thing that is assumed once and copied into four documents.

## Transport

Newline-delimited JSON in both directions, over stdin and stdout. Every frame
is one object with a `"type"` discriminator.

## Frames mesthiri sends

The command name is in `"type"`. It is **not** `command`, `method` or `cmd` —
all three are accepted as JSON and answered with
`"Unknown command: undefined"`, which is a confusing error for a wrong key
name, so this is worth knowing.

```json
{"type":"prompt","message":"…"}
```

`message` is the text field. `text` and `content` are ignored, and the
resulting error — `Cannot read properties of undefined (reading 'startsWith')`
— names neither the missing field nor the command.

Probed and **not** present in 0.84.4: `cancel`, `interrupt`, `stop`, `exit`,
`quit`, `ping`, `status`, `models`, `tools`, `session`. There is no in-band
cancel, which matters for M3: **the deadline is enforced by killing the
process group**, not by asking pi to stop. That is what mesthiri planned to
do anyway; it is now known to be the only option rather than a preference.

## Frames pi sends

Acknowledgement of a command:

```json
{"type":"response","command":"prompt","success":true}
```

Then one run's lifecycle, in order:

| Frame | Carries | Why mesthiri cares |
|---|---|---|
| `agent_start` | — | the run began |
| `turn_start` | — | a turn began; count these against the turn budget |
| `message_start` | `message` | |
| `message_update` | `usage`, `assistantMessageEvent` | **token accounting** |
| `message_end` | `message` | |
| `turn_end` | `message`, `toolResults` | tool calls made this turn |
| `agent_end` | `messages`, `willRetry` | |
| `agent_settled` | — | **terminal** — nothing follows |

`agent_settled` is what a drive fiber waits for. `agent_end` is *not*
terminal: it carries `willRetry`, and a retry produces another
`agent_start`. Treating `agent_end` as the end would truncate a retried run.

### Token accounting

`message_update` carries a complete usage object:

```json
{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,
 "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}
```

pi reports cost as well as tokens, so mesthiri's per-run budget can be
enforced against either. Note the values are cumulative per message, so a
budget check reads the latest rather than summing.

`turn_end`'s `message` additionally carries `model`, `provider`, `api`,
`stopReason` and `rawStopReason` — `model` is what the `Generated-by` trailer
needs, and taking it from here rather than from config means the trailer
records what actually ran.

### Noise to ignore

```json
{"type":"extension_ui_request","id":"…","method":"setWidget","widgetKey":"…"}
```

Emitted at startup and shutdown regardless of `--no-tools`. It is a UI
affordance for interactive use and carries nothing mesthiri wants. An unknown
frame type must be ignored rather than treated as an error, or a pi upgrade
that adds a frame breaks every run.

## Sandbox requirements (input to M3's policy)

Observed needs, to be confirmed once the sandbox is built:

- **Network**: the model provider's endpoint. With `--no-tools` nothing else
  was contacted. `--offline` suppresses startup network operations and is
  worth setting, since mesthiri pins its own versions.
- **Filesystem**: session storage under the session directory unless
  `--no-session` is passed. mesthiri passes `--no-session`: a run's record is
  the JSONL trace, and a session file in the scratch clone would end up in a
  diff.
- **Config discovery**: pi reads `AGENTS.md` and `CLAUDE.md` from the working
  directory. In a scratch clone of a target repository, those are files the
  target's contributors control — so mesthiri passes `--no-context-files`
  and supplies context deliberately instead. This is a prompt-injection path
  that would otherwise be open by default.

## A fixture

`tests/fixtures/pi-rpc-session.jsonl` is a real 15-frame session, redacted of
message content. M3's frame parser is tested against it.
