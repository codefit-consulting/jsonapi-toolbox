# Changelog

## 0.5.0

Include handling is redesigned. The gem used to expand each serializer's
`allow_includes` declarations into a list of every allowed path, and left eager
loading to each action. It now walks each request's include paths through the
serializers, and `render_jsonapi` preloads every record they reach.

### Changed

- A serializer without `allow_includes` lets clients include every
  relationship, and a path continues through whatever each serializer along it
  allows. `allow_includes` takes relationship names only, and restricts a
  serializer to them. A path may have at most `max_include_depth` segments,
  eight by default, set with `JsonapiToolbox::Serializer.configure`. That limit
  also bounds paths that follow a cycle of relationships.
- `render_jsonapi` preloads before serializing, one level of the include tree
  at a time. It loads the association behind each requested relationship and
  the associations that attributes declare, so serializing runs no further
  queries for them. It also works from records that are not ActiveRecord
  models, such as value objects that wrap records. `preload: false` skips it.
- An invalid include is a 400 whose detail names the failing segment and lists
  what can be included at that point, by JSON:API type.
- To reuse the records it preloaded while serializing, the gem prepends a small
  module to jsonapi-serializer's `FastJsonapi::Relationship`. It changes nothing
  unless the serializer params carry the gem's record store, which only
  `render_jsonapi` and `Preloader.call` add.

### Added

- `association:` and `preload:` options on `has_many`, `has_one` and
  `belongs_to`, and on their `lazy_` helpers. `association:` names another
  association, a chain such as `[ :property, :wings ]`, or `false` for a
  relationship that is a plain method. `preload:` adds associations that the
  related records always need.
- `preload_for_attributes :attribute, includes` declares the associations an
  attribute reads.
- `verify_includes!` on a serializer, and
  `JsonapiToolbox::Serializer.verify_includes!(serializers)` for many at once,
  raise `Errors::IncludeDeclarationError` listing every unusable declaration.
- `JsonapiToolbox::Serializer::IncludeTree` and `Preloader.call`, for
  preloading and serializing outside `render_jsonapi`.

### Fixed

- `?fields[type]=` for an included type no longer fails with a 500.
- Problems in 0.4's path expansion are gone with it: allowed paths that
  depended on which serializer was read first, declarations lost after the
  first read, serializer subclasses that allowed nothing, and override hashes
  that requests modified for the rest of the process.

### Removed

- The `recursive:` and `prefix:` options and dotted entries in
  `allow_includes`.
- `allowed_includes`, `build_activerecord_includes` and
  `define_include_override`.

### Upgrading

- Delete `allow_includes` where clients may include every relationship;
  otherwise reduce it to the relationship names.
- Replace each `define_include_override` with `association:` and `preload:` on
  the relationship. Move extras that an attribute of the related records needs
  to `preload_for_attributes` on that serializer.
- Delete calls to `build_activerecord_includes` and the `includes(...)` they
  fed, and any code that rewrites include paths. Keep reloads that exist for
  freshness, and set request state that association scopes read, such as
  `Current` attributes, before rendering.
- Every relationship can now be included, so each needs a serializer class
  that resolves. A relationship with a block needs `serializer:` if clients
  include anything below it.
- Call `JsonapiToolbox::Serializer.verify_includes!` on every serializer from a
  spec.

## 0.4.1

### Fixed

- **Held transactions were losing worker affinity after a quiet gap.** The
  pin to one receiver worker is a keep-alive TCP socket, and
  `net-http-persistent` drops an idle socket after **5 s** by default — shorter
  than the 10 s default heartbeat interval. After any quiet gap the client
  silently opened a fresh socket, the receiver's next free worker accepted it,
  and every later request (heartbeat, ops, commit) 404'd with
  `Transaction not found` while the real worker reaped the slot as
  `lease_expired`. Only long blocks with gaps between requests were affected.
  The dedicated connection now reconfigures its adapter with `pool_size: 1`
  and an idle timeout of **granted `lease_ttl` + `pinned_socket_idle_grace`**
  (new `Transaction` client setting, default 30 s), re-read before every
  request so it tracks the lease the receiver actually granted — the socket
  always outlives the slot. Works on Faraday 0.x, 1.x and 2.x alike (the
  version-sensitive builder surgery lives in `Client::FaradayBuilder`). The
  receiver's keep-alive timeout has to be at least `lease_ttl_max + grace` —
  Puma's `persistent_timeout` defaults to 20 s. See README "Persistent
  Connections".
- **Heartbeat no longer mistakes lost affinity for a reaped slot.** A bare
  404 on a heartbeat now stops the thread *and* logs "affinity lost" +
  emits `transaction_affinity_lost.jsonapi_toolbox`; only the typed
  `TransactionReaped` is treated as "slot legitimately gone". Transport
  failures (previously swallowed) are logged and emit
  `heartbeat_failed.jsonapi_toolbox` while the thread keeps trying.
- **Heartbeat stands down before commit/rollback instead of being killed
  after.** Killing it could interrupt a ping mid-request, which makes
  `net-http-persistent` close the pinned socket — so the commit itself would
  have travelled on a fresh socket to a random worker. The thread is now
  flagged to stop first (an in-flight ping completes and the commit queues
  behind it); the hard kill on block exit remains as a backstop. A ping that
  was queued behind the commit and sees the closed slot is not reported.

### Upgrading

- Set `persistent_timeout` in `config/puma.rb` of every app that **hosts**
  transactions to at least its `lease_ttl_max` + the clients'
  `pinned_socket_idle_grace` (defaults 120 + 30), e.g. `persistent_timeout 150`.

## 0.4.0

### Fixed

- **In-transaction errors are handed to the host app's `rescue_from`
  handlers.** `TransactionAware#with_transaction_context` used to catch every
  `OperationError` raised inside a held transaction and render it via a
  hardcoded 422/500 map, bypassing the app's error-handling policy. The
  original error now goes through `rescue_with_handler` exactly as
  `ActionController::Rescue` does, with transaction-state metadata stashed on
  `request.env`; unhandled errors fall back to the gem's structured renderer.

## 0.3.1

### Fixed

- **Don't reap a held transaction while it's actively executing an operation.**
  A single remote op that ran longer than `lease_ttl` could have its own
  transaction reaped mid-flight — even though the caller was alive and blocked
  waiting on it. The client heartbeat can't compensate: it's serialised behind
  the in-flight op on the pinned connection, so it can't send until the op
  returns. `HeldTransaction` now tracks a mutex-guarded `busy?` flag set while
  the held thread is inside a caller's operation block, and `lease_expired?`
  no longer fires while busy — an in-flight op is itself proof of liveness.
  The `hard_cap_ttl` backstop stays unconditional, so a genuinely stuck op is
  still caught. Op completion also refreshes `last_seen`, so a long op doesn't
  leave the transaction instantly reapable the moment it finishes.

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
