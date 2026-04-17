# jsonapi-toolbox: Lazy V1 transaction establishment

> **Note for the Claude reading this in the `jsonapi-toolbox` repo:** this
> plan was drafted in the V2 caller app's repo and handed over. All file
> paths in the "Changes" section are relative to the `jsonapi-toolbox`
> gem root.

## Rationale

Today, `Transaction.within_transaction(timeout_seconds: 30) { ... }` always
POSTs `/transactions` on the remote app to open a held PG transaction, even
when the block never makes a single V1 resource call. Common in V2: every
`UpdateProduct` / `CreateProduct` / `UpdateGuestHotelStay` etc. wraps its
body in `transaction(v1: true)` defensively, but plenty of those invocations
have no V1-sync eligibility in the data they touch and never make a V1 call.
Each still pays a round-trip to open, another to commit, and holds one of
the V1 server's concurrency slots for its duration.

The fix: don't create the remote transaction at block entry. Keep a
thread-local "pending" marker and materialise the transaction lazily on
the first non-transactions V1 request through the Faraday stack. If no
V1 request is made, the block exits silently — no remote work at all.

This plan is specifically for the gem. Caller apps cannot do this
optimisation themselves: they don't know whether a block will make a V1
call until they've run it.

## Current behaviour (for reference)

```ruby
# lib/jsonapi_toolbox/client/transaction.rb
def self.within_transaction(timeout_seconds: nil)
  if Thread.current[:jsonapi_toolbox_transaction_id]
    return yield  # reentrant — reuse existing txn
  end

  txn = create(timeout_seconds: timeout_seconds)   # eager: POST /transactions
  raise_on_create_errors!(txn)

  begin
    Thread.current[:jsonapi_toolbox_transaction_id] = txn.id
    result = yield(txn)
    txn.commit!
    result
  rescue StandardError
    txn.rollback! rescue nil
    raise
  ensure
    Thread.current[:jsonapi_toolbox_transaction_id] = nil
  end
end
```

Middleware (added in 0.1.1) reads `Thread.current[:jsonapi_toolbox_transaction_id]`
and attaches `X-Transaction-ID` to outgoing requests:

```ruby
# lib/jsonapi_toolbox/client/transaction_id_middleware.rb
class TransactionIdMiddleware < Faraday::Middleware
  def call(env)
    if (txn_id = Thread.current[:jsonapi_toolbox_transaction_id])
      env.request_headers["X-Transaction-ID"] = txn_id
    end
    @app.call(env)
  end
end
```

## Desired behaviour

- `within_transaction` does **not** create the remote transaction up front.
  It sets a thread-local "pending" marker and yields.
- On the first request through `TransactionIdMiddleware` whose path is NOT
  `/transactions` (i.e., a real resource call), the middleware materialises
  the transaction: POSTs `/transactions`, stores the id in the thread-local,
  attaches the header to *this* request and every subsequent one.
- On normal block exit, `commit!` is called **only if** the txn was
  actually created. If not, nothing happens — no POST, no PATCH.
- On exception, `rollback!` is called **only if** the txn was actually
  created. Same rationale — no network work for a never-opened txn.
- Reentrant calls (nested `within_transaction`) respect both an active
  txn id AND a pending marker, so inner calls join the outer.

## Changes

### 1. `lib/jsonapi_toolbox/client/transaction.rb`

Replace `within_transaction` with the lazy version:

```ruby
def self.within_transaction(timeout_seconds: nil)
  # Reentrant: active txn (already materialised) OR pending marker set by
  # an outer call that hasn't materialised yet. Either way, just yield.
  return yield(nil) if Thread.current[:jsonapi_toolbox_transaction_id] ||
                       Thread.current[:jsonapi_toolbox_pending_transaction]

  pending = { timeout_seconds: timeout_seconds, txn: nil }
  Thread.current[:jsonapi_toolbox_pending_transaction] = pending

  begin
    result = yield(nil)              # txn is nil unless/until materialised
    pending[:txn]&.commit!
    result
  rescue StandardError
    pending[:txn]&.rollback! rescue nil
    raise
  ensure
    Thread.current[:jsonapi_toolbox_pending_transaction] = nil
    Thread.current[:jsonapi_toolbox_transaction_id] = nil
  end
end
```

### 2. `lib/jsonapi_toolbox/client/transaction_id_middleware.rb`

Add on-demand materialisation, with a recursion guard for the
`/transactions` endpoint itself (otherwise the POST to create the txn
would re-enter this middleware and loop):

```ruby
class TransactionIdMiddleware < Faraday::Middleware
  HEADER = "X-Transaction-ID"

  def call(env)
    # Don't materialise the txn for calls TO the transactions endpoint
    # (that's how we create/commit/rollback txns in the first place).
    unless transactions_endpoint?(env)
      materialise_pending_transaction!
    end

    if (id = Thread.current[:jsonapi_toolbox_transaction_id]) &&
       env.request_headers[HEADER].nil?
      env.request_headers[HEADER] = id
    end

    @app.call(env)
  end

  private

  def transactions_endpoint?(env)
    # Matches .../transactions and .../transactions/<id>
    env.url.path.match?(%r{/transactions(/[^/]+)?\z})
  end

  def materialise_pending_transaction!
    pending = Thread.current[:jsonapi_toolbox_pending_transaction]
    return unless pending && pending[:txn].nil?

    txn = Transaction.create(timeout_seconds: pending[:timeout_seconds])
    Transaction.send(:raise_on_create_errors!, txn)
    pending[:txn] = txn
    Thread.current[:jsonapi_toolbox_transaction_id] = txn.id
  end
end
```

Note `Transaction.send(:raise_on_create_errors!, txn)` — the class method is
currently `private_class_method`. Either keep the `send` or make it
public.

### 3. Caller-visible semantics of `yield(nil)`

Today `within_transaction` yields the `txn` instance so callers can reach
into it (inspect `state`, call `commit!`/`rollback!` directly, etc.). The
gem's usage examples in the docstring show this:

```ruby
V1::Transaction.within_transaction(timeout_seconds: 30) do |txn|
  V1::Hotel.create!(name: "Test")
  # ...
end
```

V2's own usage in `Core::PrivateInteraction` ignores the yielded txn
— but the public API shouldn't silently break for external callers.
Two options:

**Option A — breaking API change, yield nil.** Simpler. The block
argument becomes nil-or-a-real-txn depending on whether any V1 call
happened. Callers who never used the argument (like V2) are fine.
Callers who did will get a `NoMethodError` — but any interaction with
the txn object was probably indicating they shouldn't have been using
`within_transaction` in the first place (use the lower-level API).

**Option B — yield a `LazyTransaction` proxy** that stands in for the
txn, forwards method calls to the underlying real txn (materialising
if needed on first access), and no-ops on `commit!`/`rollback!`/`state`
when no real txn was ever created:

```ruby
class LazyTransaction
  def initialize(pending)
    @pending = pending
  end

  def id;       @pending[:txn]&.id;       end
  def state;    @pending[:txn]&.state || "not_opened"; end
  def open?;    @pending[:txn]&.open? || false; end
  def commit!;  @pending[:txn]&.commit!; self; end
  def rollback!; @pending[:txn]&.rollback!; self; end
end
```

…and `within_transaction` yields a `LazyTransaction.new(pending)`.
A fresh `state` of `"not_opened"` is a useful signal to callers if they
ever inspect state after the block: "we never needed to go remote." No
simulation of a fake id — `id` is nil if nothing happened, which is
honest.

Recommend Option A on principle (less machinery, the yielded arg is
rarely used in practice) unless there's a known external caller that
uses it. Easy to revisit if we hear complaints.

## Edge cases to get right

1. **Recursion in `Transaction.create`.** When the middleware triggers
   `Transaction.create` on first V1 call, that create itself issues an
   HTTP request through the same Faraday stack. Without the
   `transactions_endpoint?` guard, this recurses infinitely. Test:
   assert the POST to `/transactions` goes out without an
   `X-Transaction-ID` header.

2. **`create`, `commit!`, `rollback!` all go through the middleware.**
   All three hit the transactions endpoint. Guard path check must match
   all of them. Current pattern `/transactions(/<id>)?` works for
   `POST /transactions`, `PATCH /transactions/<id>`, and if anyone ever
   GETs or DELETEs. Double-check with a spec.

3. **`commit!` / `rollback!` still need the header on their own PATCH.**
   Re-read the flow: after materialisation, `Thread.current[...]` is
   set. `commit!` inside the block triggers a PATCH `/transactions/<id>`
   — the middleware skips materialisation (it's a transactions-endpoint
   call) but should still attach the header (PATCH needs the id-bearing
   header to identify which held txn to commit). Today's middleware
   adds the header unconditionally when `Thread.current[...]` is set,
   so this just works — but make sure the new version preserves it:
   the materialisation skip must NOT also skip the header-attach.

4. **Reentrancy during unmaterialised outer.** If an inner
   `within_transaction` fires while only the outer's pending marker is
   set (no real txn yet), the inner must not open its own pending
   marker — that would cause the inner's exit to try to commit/rollback
   a non-existent txn, and outer's state would be bizarre. Handled by
   the `|| Thread.current[:jsonapi_toolbox_pending_transaction]` check
   at the top of `within_transaction`. Test: two nested
   `within_transaction`s, inner does no V1 call and exits; outer then
   does a V1 call; assert exactly one `POST /transactions` was issued
   and one `PATCH state=committed` at the end.

5. **Exception thrown before any V1 call.** Outer block raises before
   any V1 work happens. `pending[:txn]` is nil, so the `rescue`
   branch's `pending[:txn]&.rollback!` is a no-op. The exception
   re-raises to the caller. Clean.

6. **Timeout clock.** Today the 30s countdown starts at `within_transaction`
   entry. With lazy, it starts at first V1 call — potentially much later
   if the caller does significant V2-only work first. This is a
   behaviour change. **Call it out in the changelog.** It's almost
   certainly what callers want (longer V2 work at the start of a block
   is now safer), but someone might depend on "total block duration
   capped at 30s" for other reasons.

7. **Concurrency-cap accounting on the V1 side.** Today's slot-reservation
   happens at block entry. With lazy, it happens only when needed — a
   V1-free block doesn't consume a slot. This is strictly better, no
   change needed on V1 side.

8. **Error timing for `raise_on_create_errors!`.** Today the create-time
   error (e.g., concurrency limit reached on the V1 side) raises from
   `within_transaction`'s own stack frame. With lazy, it raises from
   inside the middleware, on the caller's first resource call. Callers
   who rescued `JsonapiToolbox::Transaction::Errors::ConcurrencyLimitError`
   around `within_transaction` entry will still catch it — the raise
   still propagates out through the block — but the stack trace now
   points at their resource call, not the block entry. Minor diagnostic
   hit; mention in the changelog.

## Test plan

Add `spec/transaction/lazy_within_transaction_spec.rb`:

1. **No V1 call → no remote round-trip.**
   `V1::Transaction.within_transaction { } # body empty`.
   Stub the Faraday adapter; assert zero requests to `/transactions`.

2. **First V1 call materialises once.**
   `within_transaction { V1::Widget.create; V1::Widget.create }`.
   Assert exactly one `POST /transactions` (before first widget POST),
   two `POST /widgets` with `X-Transaction-ID`, one `PATCH /transactions/<id>`
   with `state=committed`.

3. **Exception before first V1 call → no remote work.**
   `within_transaction { raise "oops" }`. Assert zero requests to
   `/transactions`. Exception re-raises to caller.

4. **Exception after first V1 call → rollback PATCH fires.**
   `within_transaction { V1::Widget.create; raise "oops" }`. Assert
   `POST /transactions` → `POST /widgets` → `PATCH /transactions/<id>
   state=rolled_back`.

5. **Reentrant with V1 call inside outer only.**
   ```
   within_transaction do
     within_transaction { }          # inner no-op
     V1::Widget.create               # outer first V1 call
   end
   ```
   Assert exactly one `POST /transactions`, one `POST /widgets`
   carrying the outer id, one `PATCH state=committed`.

6. **Reentrant with V1 call in inner block.**
   ```
   within_transaction do
     within_transaction { V1::Widget.create }
   end
   ```
   Assert exactly one `POST /transactions` (outer marker wins), one
   `POST /widgets` with the outer's id, one commit at the end.

7. **Middleware guard — `Transaction.create` itself doesn't recurse.**
   Stub `Transaction.create` to assert the outgoing POST to
   `/transactions` carries NO `X-Transaction-ID` header (we're creating
   it — there's nothing to attach yet).

8. **Header attachment preserved for commit/rollback PATCH.** The
   `PATCH /transactions/<id>` should still carry `X-Transaction-ID`
   even though the middleware's materialisation branch is skipped for
   transactions-endpoint calls.

Existing specs to audit for assumptions about eager creation:
`spec/transaction/transaction_client_spec.rb`,
`spec/transaction/held_transaction_spec.rb`,
`spec/transaction/manager_spec.rb`. Probably fine — most test the
held-transaction server side rather than the client `within_transaction`
wrapper — but scan for any `expect(Transaction).to receive(:create)`
that assumes eager call.

## Version bump

Patch bump is defensible (optimisation, no public API change if we go
with Option B / `LazyTransaction`). Minor bump if we go with Option A
(block-arg type changes from `Transaction` to `nil`-or-`Transaction`,
which is technically a breaking change even if nobody's noticed).

Recommendation: **0.2.0** either way. The changelog entry is notable
enough (behaviour change in timeout clock, error timing, slot
accounting) that signalling "pay attention" via a minor bump is worth
it even without strict API break.

### CHANGELOG

```markdown
## [0.2.0] - <date>

### Changed
- `Transaction.within_transaction` is now lazy: the remote held
  transaction is only created on the first V1 resource request made
  inside the block. Blocks that make no V1 calls issue zero remote
  requests. No action required in caller apps — existing usage just
  gets faster.

### Behaviour notes
- The 30-second timeout clock now starts at the first V1 call rather
  than at block entry. Long V2-only work at the start of a block is
  now safer.
- Concurrency-cap slot reservation (on the V1-side Transaction
  service) happens only when a held transaction is actually needed.
- `raise_on_create_errors!` now raises from the caller's first
  resource-call stack frame rather than from the `within_transaction`
  entry. Error class unchanged; stack trace shifts slightly.
```

## Out of scope

- No change to `HeldTransaction` / `Manager` (server-side) logic.
  They're unaffected — they only care about requests that arrive.
- No change to `ServiceTokenMiddleware` or `Base#configure_service_token`.
- No change to the `TransactionAware`/`TransactionsActions` controller
  concerns in caller V1 apps.
