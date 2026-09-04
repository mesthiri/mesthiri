# mesthiri — architecture

Status: derived document, 2026-09-04. [design.md](design.md) is the design
authority and [plan.md](plan.md) sequences the work; this file only draws
what those two describe. If a diagram here disagrees with design.md,
design.md is right and the diagram is stale — fix it.

Diagrams are Mermaid, so they render on GitHub without a build step.

## 1. Deployment and trust zones

One process on one server. Everything mesthiri touches is either inside the
process, inside the agent's sandbox, or reached over outbound HTTPS —
nothing listens on an inbound port.

```mermaid
flowchart LR
  subgraph host["Your server, under systemd"]
    direction TB
    svc["mesthiri<br/>one process, fibers"]
    db[("SQLite<br/>pipeline state")]
    keys["secrets dir<br/>App private key, 0600"]
    subgraph sbx["namespace sandbox, unprivileged uid"]
      direction TB
      agent["pi --rpc<br/>coding agent"]
      clone["scratch clone<br/>only writable mount"]
    end
    svc --> db
    svc --> keys
    svc -->|"spawn-process<br/>JSON over stdio"| agent
    svc -->|"clone, read diff, push"| clone
    agent --> clone
  end

  svc -->|"outbound HTTPS<br/>installation token"| gh["GitHub REST API"]
  agent -->|"egress allowlist:<br/>registries, model endpoint"| net["internet"]
  agent --x gh

  classDef danger fill:#fff0f0,stroke:#c33
  classDef safe fill:#f2f8f2,stroke:#396
  class agent,clone danger
  class svc,db,keys safe
```

The crossed edge is the load-bearing one: **the agent has no credential and
no route to the forge.** The secrets directory is outside its mount
namespace — unreachable rather than merely unreadable — and the forge is
deliberately absent from its egress allowlist.

| Zone | Trust | Holds |
|---|---|---|
| Service | trusted | credentials, store, all forge calls, all policy decisions |
| Sandbox | untrusted | the agent and the scratch clone it may write |
| Forge | untrusted input | issue and PR text, authored by anyone |

## 2. How a stage gets woken

Three sources, one shape. Routing and authorization happen once, in one
place, regardless of which source fired.

```mermaid
flowchart TD
  cron["reactor timer<br/>triage, prioritize, retro"] --> ev
  queue["ready queue<br/>code, fix"] --> ev
  poll["forge poll<br/>cursor + ETag per event class"] --> ev

  ev["event.sld<br/>normalized event"] --> auth{"authorized?<br/>commenter's repo permission"}
  auth -->|"no"| refuse["refusal comment<br/>saying which rule fired"]
  auth -->|"yes"| dedupe{"id already<br/>recorded handled?"}
  dedupe -->|"yes"| drop["drop, idempotent"]
  dedupe -->|"no"| elig{"eligible?<br/>intent tier + path denylist"}
  elig -->|"no"| escalate["needs-human"]
  elig -->|"yes"| stage["run the stage"]
  stage --> mark["record handled,<br/>advance watermark"]
```

Polling is the only delivery mechanism; there is no webhook receiver and no
driver indirection standing in for one. The watermark advances only *after*
work is recorded handled, so a crash mid-stage replays rather than loses.

## 3. The lifecycle

```mermaid
flowchart LR
  issue(["new issue"]) --> tri
  tri["Triage<br/>verify claims<br/>priority + intent tier"] --> pri
  pri["Prioritize<br/>rank into ready queue"] --> code
  code["Code<br/>agent implements<br/>service pushes"] --> pr(["pull request"])
  pr --> rev
  rev["Review<br/>correctness, security,<br/>performance, intent"]
  rev -->|"findings"| fix["Fix<br/>bounded iterations"]
  fix --> rev
  rev -->|"clean"| gate{{"HUMAN<br/>reviews and merges"}}
  fix -->|"depth exhausted"| gate
  gate --> merged(["merged"])
  merged --> retro["Retro<br/>mine run records"]
  retro -->|"proposals as issues<br/>on mesthiri"| human2{{"HUMAN<br/>implements them"}}

  style gate fill:#ffe9b3,stroke:#b8860b,stroke-width:2px
  style human2 fill:#ffe9b3,stroke:#b8860b,stroke-width:2px
```

The two shaded boxes are the only places a human is mandatory, and both are
structural rather than procedural: the App holds no merge permission, and
mesthiri is never configured as a target of its own pipeline, so it cannot
implement the retro proposals it files.

## 4. The code stage, at the credential boundary

The sharpest thing in the design, and the hardest to see in prose. The
agent's job ends at "commits exist in a directory".

```mermaid
sequenceDiagram
  autonumber
  participant Q as ready queue
  participant S as service
  participant A as agent in sandbox
  participant G as GitHub

  Q->>S: claim issue, round-robin across targets
  S->>S: eligibility — intent tier, path denylist
  S->>G: clone target with installation token
  S->>A: spawn in sandbox<br/>prompt + issue text marked untrusted
  loop within token and wall-clock budget
    A->>A: edit files in scratch clone
    A->>A: run the target project's own test command
  end
  A-->>S: exits, leaving commits in the clone
  Note over A,G: no credential, no route to the forge —<br/>the agent cannot deliver anything itself
  S->>S: read the finished diff, re-check denylist
  alt diff is clean and in scope
    S->>G: push branch, open PR, never merge
  else denied path or budget exhausted
    S->>G: comment on the issue with the actual state
  end
```

Step 3 and the final step are the only moments a credential is used, and
both happen outside the sandbox. The eligibility check sits *on* the path a
change takes to GitHub rather than beside it — there is no second path.

## 5. Workflow labels

Workflow state lives on the target repo where a human can read it and change
it, not only in mesthiri's database. Transitions are guarded, states are
mutually exclusive, and every write is read back to confirm it took.

```mermaid
stateDiagram-v2
  [*] --> ready_for_triage
  ready_for_triage --> triaged: verdict recorded
  triaged --> ready_to_implement: prioritized
  triaged --> needs_human: tier 2, no authorization
  ready_to_implement --> in_progress: claimed
  in_progress --> ready_for_review: PR opened
  in_progress --> needs_human: tests never green
  ready_for_review --> needs_fix: findings posted
  needs_fix --> ready_for_review: fixes pushed
  ready_for_review --> ready_for_merge: review clean
  needs_fix --> needs_human: iteration depth exhausted
  ready_for_merge --> [*]: human merges
  needs_human --> [*]: human takes over
```

The rule that earns the machine its keep is not drawn as a transition
because it applies from almost everywhere: **a new commit clears every
downstream label**, so a `ready_for_merge` earned by one head cannot survive
the push that invalidated it.

## 6. Module map

Control flows downward. `agent.sld` is the only module that spawns the
coding agent; `forge.sld` is the only module that talks to the GitHub API.
A second agent backend or a second forge is a new module at those two
seams, not a change to any stage.

```mermaid
flowchart TD
  main["mesthiri.scm<br/>entry point, reactor"]

  subgraph stages["stages"]
    direction LR
    triage["triage.sld"]
    prioritize["prioritize.sld*"]
    codestage["code.sld*"]
    review["review.sld*"]
    fixstage["fix.sld*"]
    retro["retro.sld*"]
  end

  subgraph plumbing["plumbing"]
    direction LR
    event["event.sld"]
    command["command.sld"]
    labels["labels.sld"]
  end

  subgraph seams["the two seams"]
    direction LR
    agentmod["agent.sld<br/>only spawner<br/>+ sandbox + budgets"]
    forge["forge.sld<br/>only API client<br/>+ pagination + limits"]
  end

  subgraph base["foundations"]
    direction LR
    store["store.sld"]
    config["config.sld"]
    logmod["log.sld"]
    jwt["jwt.sld"]
    proc["proc.sld<br/>run/spawn-process"]
  end

  main --> stages
  main --> plumbing
  stages --> seams
  plumbing --> seams
  plumbing --> store
  seams --> base
  forge --> jwt
  jwt --> proc
  agentmod --> proc
  stages --> store
  stages --> logmod
  seams --> config

  classDef prov stroke-dasharray: 4 3
  class prioritize,codestage,review,fixstage,retro prov
```

`*` — dashed modules are the stage bodies for milestones M5 onward; their
names are indicative, since [plan.md](plan.md) has not fixed them yet.
Everything else is named in the plan.

## 7. External dependencies

```mermaid
flowchart LR
  subgraph kaappi["Kaappi ecosystem"]
    direction TB
    http["kaappi-http"]
    json["kaappi-json"]
    sqlite["kaappi-sqlite"]
    log2["kaappi-log"]
    cli["kaappi-cli"]
    net["kaappi-net"]
  end
  subgraph binaries["host binaries"]
    direction TB
    git["git"]
    openssl["openssl<br/>RS256 for the App JWT"]
    bwrap["bwrap / unshare"]
    pi["pi"]
  end
  subgraph core["kaappi core, >= 0.26"]
    process["(kaappi process)<br/>KEP-0022"]
    fibers["fibers + reactor"]
  end
  m["mesthiri"] --> kaappi
  m --> binaries
  m --> core
  http --> net
```

Deliberately absent: `kaappi-crypto` (RS256 is one `openssl` call, and
depending on a feature that does not exist yet put another repo's release on
this one's critical path), `gh` (`forge.sld` is the only API path), and any
inbound HTTP server.
