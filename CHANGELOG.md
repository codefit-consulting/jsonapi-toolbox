# Changelog

## 0.3.0

Held-transaction reliability: crash-only timeouts, legible reap errors, and
observability. See `docs/plans/transaction-reliability.md`.

### Legible reap errors (§1)

- **Receiver** now distinguishes a *reaped* slot from one that *never existed*.
  The reaper records a bounded tombstone, so a follow-up request raises
  `Transaction::Errors::ReapedError` (with `reason`) rather than a generic
  not-found. The controller renders a JSON:API `title` (not only `detail`) plus
  `meta: { transaction_id, transaction_reaped: true, reason }`.
- **Client** gains `JsonapiToolbox::Client::TransactionReaped` (a `NotFound`
  subclass carrying `transaction_id` + `reason`) and a response middleware that
  raises it when `meta.transaction_reaped` is set — no more string-scraping a
  misleading `"Resource not found: <url>"`.

### Crash-only lease + heartbeat timeout (§2 / §4)

- **Removed the silent `max_timeout = 60` clamp.** A caller can now be granted
  the lease/`hard_cap_ttl` it needs; the receiver echoes the granted values in
  the create response.
- **Negotiated lease model.** `Manager#create` accepts `requested_lease_ttl` /
  `requested_hard_cap_ttl`, clamps them to receiver policy, stores the grant,
  and the serializer echoes `lease_ttl` + `hard_cap_ttl` back to the client.
  These are also settable per-transaction on `within_transaction`.
- **`HeldTransaction`** tracks `last_seen_at`, `op_count`, `lease_ttl`, and a
  nil-able `hard_cap_ttl` on a **monotonic** clock. `touch!` refreshes liveness
  on any heartbeat or real op. The reaper reaps only on `lease_expired` (caller
  went silent) or `hard_cap_ttl_exceeded` (runaway).
- **Heartbeat endpoint**: `POST /transactions/:id/heartbeat` (add the route +
  the `heartbeat` action ships in `TransactionsActions`).
- **Automatic client heartbeat**: a background thread bound to the transaction
  lifecycle POSTs heartbeats at `granted_ttl / heartbeat_divisor` (floored at
  `heartbeat_min_interval`), stopped on commit/rollback. A per-connection
  request serialiser keeps it from racing real requests on the pinned socket.
- **Config**: `Transaction::Configuration` replaces `default_timeout` /
  `max_timeout` / `reaper_interval` with the lease/heartbeat set —
  `lease_ttl_default/min/max`, `hard_cap_ttl_default/max` (nil-able),
  `reaper_scan_interval`, `heartbeat_divisor`, `heartbeat_min_interval`,
  `requested_lease_ttl`, `requested_hard_cap_ttl`. Every value defaulted; the gem
  never reads ENV.

### Observability (§6)

- The gem emits plain `ActiveSupport::Notifications` (no metrics-library
  dependency): `transaction_materialized`, `transaction_committed`,
  `transaction_rolled_back`, `transaction_reaped` (carrying `reason`,
  `idle_for`, `age`, `op_count`), and per-op `transaction_operation`. All under
  the `.jsonapi_toolbox` namespace.

### Not included

- Transparent write-batching (§5 in the plan) remains **deferred / not built**.

### Upgrading

- Add the heartbeat route alongside your transactions resource:
  `post "transactions/:id/heartbeat", to: "transactions#heartbeat"`.
- If you set `default_timeout` / `max_timeout` / `reaper_interval` in an
  initializer, migrate to `lease_ttl_default` / (the clamp is gone; use
  `hard_cap_ttl_*`) / `reaper_scan_interval`.
- `within_transaction(timeout_seconds:)` is **removed**. Pass
  `requested_lease_ttl:` / `requested_hard_cap_ttl:` instead (both optional,
  both clamped by the receiver), or nothing to take the server defaults.
