# Plan: Held-transaction reliability — timeouts, error legibility & observability

This plan covers a set of improvements to the `jsonapi-toolbox` held-transaction
feature (`lib/jsonapi_toolbox/transaction/` and the transaction client). It is
scoped entirely to the gem: the machinery a **client** uses to open a remote
transaction, and the machinery a **receiver** uses to host one.

The theme is **making a long-running remote transaction fail only when the
caller has actually died, and making that failure legible when it happens** —
plus the instrumentation needed to tune it from data rather than anecdote.

> **Compatibility constraint (applies to every change):** the gem must run under
> **Ruby 2.6 / Rails 4.2** as well as modern Rubies. No pattern matching
> (`case/in`), no endless methods, no core `Hash#except` (use ActiveSupport), no
> one-line endless-method `rescue`. Keep the existing `Mutex`/`Thread`/`Queue` +
> explicit-`return` style.

---

## Design principles

1. **No hard cut-offs except for genuine crashes.** A blind fixed deadline is
   the wrong model. A transaction should stay open as long as the caller is
   demonstrably alive and making progress; it should be reaped only when the
   caller has actually died.
2. **Make failures self-describing.** When a transaction *is* reaped, the caller
   should get a typed, unambiguous error naming the transaction and the reason —
   not a misleading generic "not found".
3. **Make behaviour visible.** Emit events for transaction lifecycle, per-op
   HTTP, and reaps, so operators can tune from metrics rather than anecdote.
4. **Keep the gem dependency-light.** Instrumentation ships as plain
   `ActiveSupport::Notifications` so any host — including Rails 4.2 — can
   subscribe with whatever exporter it can load.

---

## 1 — Legible reap errors *(ship first — it's independent)*

### The problem

When the receiver reaps an expired transaction slot, it currently renders the
human-readable message under the JSON:API `detail` key with **no `title`**. The
`json_api_client` error harvester reads **only `title`**, so it finds nothing,
falls back to its `"Resource not found: <url>"` default, and raises a generic
`NotFound`. The clear signal the receiver produced ("transaction not found /
reaped") is discarded on the wire, and the caller sees a misleading 404 about a
resource that actually exists.

### The fix — a typed signal, no string-scraping

1. **Receiver:** on a reaped/expired slot, render **`title`** (so the harvester
   picks it up) **and** structured meta:
   `meta: { transaction_id:, transaction_reaped: true, reason: }`.
2. **Client:** a response middleware inspects `meta.transaction_reaped` and
   raises a typed `JsonapiToolbox::Client::TransactionReaped` carrying the
   transaction id and reason — instead of a generic `NotFound`.
3. Callers can then rescue the typed error and render a clear message
   (e.g. *"the remote transaction was reaped after N s of caller inactivity — the
   operation did not complete; nothing was saved"*) rather than string-scraping a
   degraded message.

This is a small change and it's independent of everything below, so it ships
first: it makes the next timeout incident self-describing.

**Checklist**

- [ ] `render_transaction_error` includes a `title` (not only `detail`) and adds
      `meta: { transaction_id:, transaction_reaped: true, reason: }` on the
      reaped/expired path.
- [ ] Client response middleware raises `TransactionReaped` (carrying id +
      reason) when `meta.transaction_reaped` is set.
- [ ] Test: a reaped-slot request raises `TransactionReaped`, not `NotFound`,
      and the message names the transaction, not the resource URL.

---

## 2 — A crash-only timeout: lease + automatic heartbeat

### The problem

Today the transaction lifetime is a blind fixed deadline. Two failure modes fall
out of that:

- **A legitimate long fan-out** (hundreds of serial writes) can straddle the
  deadline and be reaped mid-flight even though the caller is alive and working.
- **The requested timeout is silently clamped.** A caller asking for, say, 300 s
  is quietly truncated to a `max_timeout` (60 s) ceiling — a latent correctness
  bug for every long legitimate operation, with no signal that it happened.

### The model — negotiated lease, renewed by heartbeat

Borrowed from lease/session systems (Consul & etcd session *TTL + renew*, gRPC
keepalive, DHCP lease renewal, Postgres
`idle_in_transaction_session_timeout`): **the receiver is the single source of
truth for reaping, and the client learns the effective numbers at creation.** So
the two sides never need matching constants — they negotiate.

- **The client runs an automatic heartbeat**, bound to the transaction
  lifecycle — no caller code ever touches it. On materialisation the client
  starts a background thread that `POST`s a cheap `/transactions/:id/heartbeat`
  every `granted_ttl / heartbeat_divisor`, stopped at commit **and** rollback.
- **The receiver stores `last_seen_at`** and reaps a transaction **iff** the
  caller has gone silent for longer than the granted lease — i.e. the caller
  process has actually died (crash, OOM-kill, network partition). A real op
  carrying the transaction id refreshes `last_seen_at` as a free side-effect, so
  traffic lets the client skip a heartbeat tick; the receiver still watches
  exactly one thing — heartbeat freshness.

```
CLIENT (gem, automatic)                    RECEIVER (gem)
on materialise: start heartbeat thread     on any message w/ X-Transaction-ID
  loop: POST /transactions/:id/heartbeat     (heartbeat OR real op): last_seen_at = now
        sleep granted_ttl / divisor        reaper: reap iff now > last_seen_at + lease_ttl
on commit/rollback: stop the thread                 (== caller is dead)
```

This makes the *only* routine reason a transaction dies "the caller is gone",
which is what a timeout should mean. A fan-out of hundreds of serial writes is
never reaped mid-flight; a long *quiet* local computation between two remote
calls is never reaped, because the heartbeat keeps firing while the process
lives.

> **MRI note:** the heartbeat is a background thread; MRI's timer-based GVL
> preemption (~100 ms) schedules it even during a CPU-bound Ruby loop. Only a
> GVL-hogging C-extension or a *hung* (not crashed) worker could starve it —
> caught, if at all, by the `hard_cap_ttl` backstop below.

### The one hard cutoff — a nil-able runaway sanity check

Heartbeat-only liveness cannot distinguish "alive and working" from "alive and
stuck in an infinite loop" — both keep heartbeating. So there is **one** hard
cutoff, `hard_cap_ttl`: an absolute maximum lifetime regardless of heartbeats. It is
a **runaway sanity check, not a routine deadline** — default generous (~1 h) and
**settable to `nil` to disable entirely**. A caller may request a per-transaction
`hard_cap_ttl` (e.g. scaled to a worst-case up-front estimate of the work), clamped
only by the receiver's `hard_cap_ttl_max`.

Config comment to ship with it: *your app should never need — or ask — to hold a
single remote transaction open anywhere near this long; if it trips, something is
genuinely wrong (a runaway that keeps heartbeating), not merely slow.*

### Config & negotiation

Everything lives on a `JsonapiToolbox::Transaction.configure` block with **a
default for every value**; a host overrides whichever it wants, from ENV or
literals — the host's choice (**the gem never reads ENV itself**).

**Receiver policy** (authoritative when this host *hosts* a transaction):

| key                               | default          | nullable               | meaning                                                                        |
| --------------------------------- | ---------------- | ---------------------- | ------------------------------------------------------------------------------ |
| `lease_ttl_default`               | 30 s             | no                     | lease granted when the client requests none — reap if silent this long         |
| `lease_ttl_min` / `lease_ttl_max` | 10 s / 120 s     | no                     | clamp range for a client-requested lease                                       |
| `hard_cap_ttl_default`                | 3600 s (1 h)     | **yes — nil disables** | absolute max lifetime regardless of heartbeats; the runaway sanity check       |
| `hard_cap_ttl_max`                    | 3600 s           | yes                    | clamp for a client-requested hard_cap_ttl                                          |
| `reaper_scan_interval`            | 5 s              | no                     | how often the reaper scans (reap-latency granularity; needn't agree w/ anyone) |

**Client policy** (used when this host *initiates* a transaction):

| key                      | default              | meaning                                                                                     |
| ------------------------ | -------------------- | ------------------------------------------------------------------------------------------- |
| `heartbeat_divisor`      | 3                    | heartbeats per lease window → tolerate `divisor − 1` misses; interval = `granted_ttl / divisor` |
| `heartbeat_min_interval` | 2 s                  | floor, so a small lease can't cause a heartbeat storm                                       |
| `requested_lease_ttl`    | nil → server default | optional per-host / per-txn lease request                                                    |
| `requested_hard_cap_ttl`     | nil → server default | optional per-txn override                                                                    |

**How the two sides agree — at creation, not via shared config:**

1. On `POST /transactions` the client sends its `requested_lease_ttl` /
   `requested_hard_cap_ttl` (or nothing).
2. The receiver **clamps** them to its own policy, **stores the granted values**
   on the held transaction, and **echoes them in the create response**.
3. The client reads the **granted** `lease_ttl` back and sets its heartbeat
   cadence to `max(granted_ttl / heartbeat_divisor, heartbeat_min_interval)` —
   so even after a clamp, the client's rate stays consistent with what the
   receiver enforces.

A mismatch between the two sides is impossible: whichever host is the *receiver*
for a given call dictates and returns the effective lease. (A gRPC-style
refinement, if ever wanted: the receiver may `429` a client heartbeating faster
than `lease_ttl_min / divisor`, the way gRPC sends GOAWAY for `too_many_pings`.
Not needed day one.)

### What the receiver computes to decide a reap

```ruby
# Receiver, in the gem. Runs every `reaper_scan_interval` on a background thread.
def reap_expired
  now = monotonic_now
  open = @mutex.synchronize { @transactions.values.select(&:open?) }
  open.each do |txn|
    idle_for = now - txn.last_seen_at          # since last heartbeat OR real op
    age      = now - txn.created_at

    lease_expired = idle_for > txn.lease_ttl                 # client went silent → crashed
    hard_capped   = txn.hard_cap_ttl && age > txn.hard_cap_ttl       # alive but runaway

    next unless lease_expired || hard_capped

    reason = lease_expired ? :lease_expired : :hard_cap_ttl_exceeded
    emit(:transaction_reaped, id: txn.id, reason:, idle_for:, age:, op_count: txn.op_count)
    txn.rollback!
    remove(txn.id)
  end
end

# Any inbound request OR heartbeat carrying X-Transaction-ID, before dispatch:
def touch!(txn)
  @mutex.synchronize { txn.last_seen_at = monotonic_now }    # a real op counts as a heartbeat
end
```

Two independent reap reasons, surfaced distinctly (via §1's typed error and §3's
metric):

- **`lease_expired`** — the caller stopped heartbeating (crash / OOM / network
  partition). The normal, legitimate reap.
- **`hard_cap_ttl_exceeded`** — the caller is alive and still heartbeating but has
  blown the absolute ceiling. A runaway.

Use a **monotonic** clock so an NTP step can't cause a false reap. Worst-case
reap latency is `lease_ttl + reaper_scan_interval`.

**Checklist**

- [ ] **Config:** extend `Transaction::Configuration` with every value above,
      each with a default. Gem never reads ENV.
- [ ] **Delete the `max_timeout = 60` clamp** in `Manager#create` — no more
      silent truncation; the receiver echoes the granted lease + hard_cap_ttl.
- [ ] **`HeldTransaction`:** add `last_seen_at`, `lease_ttl`, `hard_cap_ttl`,
      `op_count`; mutex-guarded `touch!`; replace `expires_at`/`expired?` with
      the lease + hard_cap_ttl predicates. Monotonic clock throughout.
- [ ] **Create negotiation:** `create` reads the requested values, clamps to
      policy, stores the granted values, and echoes them in the response (extend
      the serializer). Ship the `hard_cap_ttl` config comment next to its default.
- [ ] **Touch on activity:** the request-dispatch path calls `touch!` and bumps
      `op_count` on every op carrying `X-Transaction-ID`.
- [ ] **Heartbeat endpoint:** `POST /transactions/:id/heartbeat` → `touch!` +
      `204`. Document the one route line a host adds.
- [ ] **Reaper:** `reap_expired` uses `lease_expired || hard_cap_ttl_exceeded` and
      emits the reap event (reason, idle_for, age, op_count).
- [ ] **Client heartbeat thread:** started at materialisation, stopped at commit
      **and** rollback (ensure cleanup on the error path); cadence =
      `max(granted_ttl / heartbeat_divisor, heartbeat_min_interval)`, read from
      the create response. One thread per transaction; never leak it.
- [ ] Tests: a fan-out of N ops is never reaped while heartbeating; a killed
      client (no heartbeat) is reaped after `lease_ttl + scan_interval`; a client
      requesting 300 s hard_cap_ttl gets it (not clamped to 60); a request exceeding
      `hard_cap_ttl` reaps with `hard_cap_ttl_exceeded`.

---

## 3 — Observability

Instrument from the gem so every host and caller gets it free. Emit via
`ActiveSupport::Notifications` (version-agnostic — works under Rails 4.2), and
**depend on no metrics library in the gem** so each host can subscribe with
whatever exporter it can load.

**Events:**

- **Transaction lifecycle** — materialise / commit / rollback, with duration and
  op-count.
- **Per-op HTTP** — endpoint, verb, status, duration, and whether it ran inside a
  transaction.
- **Reaps** — the one unambiguous "caller died / budget blown" signal, carrying
  `reason`, `idle_for`, `age`, and `op_count`.

Downstream hosts subscribe and export however they like (e.g. Prometheus);
publishing the final event/metric names lets dashboards and alerts be built
against them.

**Checklist**

- [ ] Emit `AS::Notifications` for lifecycle, per-op HTTP, and reaps with the
      payloads above.
- [ ] No metrics-library dependency in the gem — plain `AS::Notifications` only.

---

## 4 — Deferred: transparent write-batching *(not planned)*

Once change-detection at the call sites zeroes traffic when little changed, and
the crash-only timeout removes the hard deadline, transparent batching drops from
*"needed to avoid reaps"* to a pure wall-clock latency optimisation for large
legitimate syncs — a slow run now **completes** (the heartbeat keeps it alive)
instead of being reaped. **We're choosing not to build it now.** It is recorded
here so the revival path is explicit.

If revived, it stays **gem-hidden** (zero caller code change):

- **Phase 1 — transparent PATCH/DELETE-by-known-id buffer.** A gem-side buffer,
  active only inside a transaction, intercepts `save`/`destroy` to a known id and
  enqueues it (returning optimistic success — errors surface at flush and roll
  the whole transaction back anyway). A read or a create-needing-id-readback
  auto-flushes the buffer first, preserving read-your-writes and the
  "`save` returns an id" contract. Commit flushes the buffer as one
  `POST /operations` (JSON:API atomic-operations extension) on the same pinned
  connection; the receiver de-batches and applies each op serially inside the
  held transaction. The win is eliminating N−1 HTTP round-trips and N−1 host
  dispatches — the DB work is inherently serial (one held PG connection) and was
  never the bottleneck.
- **Phase 2 — `lid`-based create batching.** Client-minted local ids let
  create-heavy paths batch too, at the cost of client-generated ids leaking into
  callers — a deliberate later decision.

Revive only if metrics (§3) show large legitimate syncs hurting latency; Phase 1
first, then Phase 2.

---

## Build order

1. **§1 legible reap errors** — independent; makes the next timeout incident
   self-describing.
2. **Delete the silent `max_timeout` clamp + config-drive the timeouts** — the
   biggest single correctness win.
3. **§2 crash-only lease + heartbeat** — the new timeout model.
4. **§3 observability** — instrument so the timeout model is measured, not
   guessed.
5. **§4 batching — deferred.** Revive only if metrics show large syncs hurting.

## Release

- [ ] Version bump. Note in the changelog which of §1 / §2 / §3 landed so hosts
      know what they get when they re-pin.
