# Plan: Cross-App Transaction Resource

This document describes a **held transaction** pattern for atomic cross-app mutations between v1 (Rails 4.2) and v2 (Rails 7.2). Both apps use the shared `jsonapi-toolbox` gem, which is the home for the core machinery.

**The problem:** When one app needs to mutate multiple records in the other atomically (e.g., create a hotel + room types + allocations), the compensating-saga pattern requires complex undo logic for each operation. A Transaction Resource lets the caller open a real PG transaction in the remote app, perform multiple API calls within it, and commit or rollback the whole thing.

**Both apps need this capability** in both directions (v2→v1 and v1→v2).

---

## How It Works

```text
Calling App                             Receiving App
───────────                             ─────────────
ActiveRecord::Base.transaction do
  POST /transactions {timeout: 30}  ──> Manager creates HeldTransaction
                                        (background thread, AR connection, BEGIN)
  <── {id: "abc-123", state: "open"}

  with_headers("X-Transaction-ID: abc-123") do
    POST /hotels {name: "Test"}     ──> TransactionAware detects header
                                        Executes Hotel.create! on held txn thread
                                        (SAVEPOINT, execute, RELEASE SAVEPOINT)
    <── {id: 1, name: "Test"}

    POST /room_types {hotel: 1}     ──> Same held transaction, same PG txn
    <── {id: 5, type: "Suite"}

    local_record.save!                  # local work also inside the block
  end

  PATCH /transactions/abc-123/commit ─> Manager.commit → COMMIT
  <── {state: "committed"}
end                                     # caller auto-commits
```

If anything fails, the remote transaction rolls back (explicitly or via timeout), and the caller's `ActiveRecord::Rollback` unwinds the local transaction too.

---

## Architecture: What Lives Where

### In `jsonapi-toolbox` gem (shared by both apps)

The transaction feature follows the gem's existing opt-in pattern. ActiveRecord is NOT added to the gemspec — both apps already have it, and the module is loaded conditionally.

| New gem path | Purpose |
| --- | --- |
| `lib/jsonapi_toolbox/transaction.rb` | Entry point; loads all transaction modules |
| `lib/jsonapi_toolbox/transaction/held_transaction.rb` | Thread + AR connection + operation queue + timeout |
| `lib/jsonapi_toolbox/transaction/manager.rb` | Singleton: creates/finds/reaps held transactions |
| `lib/jsonapi_toolbox/transaction/errors.rb` | NotFound, Expired, ConcurrencyLimit errors |
| `lib/jsonapi_toolbox/controller/transaction_aware.rb` | Server concern: `with_transaction_context` |
| `lib/jsonapi_toolbox/client/transaction_client.rb` | Client: create, commit, rollback via Faraday |

**Opt-in loading:**

```ruby
# In an initializer or engine config
require "jsonapi_toolbox/transaction"

JsonapiToolbox::Transaction.configure do |config|
  config.max_concurrent = 10        # max held transactions per process
  config.default_timeout = 30       # seconds
  config.max_timeout = 60           # server-side cap
  config.reaper_interval = 5        # seconds between reaper sweeps
end
```

### In v2 (Rails 7.2, CBRA with Core gem)

| File | Purpose |
| --- | --- |
| `components/core/app/controllers/core/api/internal/transactions_controller.rb` | REST endpoints for held transactions (server-side, for v1→v2 calls) |
| `components/core/app/serializers/core/api/internal/transaction_serializer.rb` | JSON:API serializer |
| `components/core/config/routes/internal_api.rb` | Routes: `/api/internal/core/transactions` |
| `components/core/app/clients/v1/transaction.rb` | Wraps gem's `TransactionClient` pointed at V1 |
| `components/core/app/private/core/private_interaction.rb` | `v1_transaction` helper method |

### In v1 (Rails 4.2, no Core gem, no interactions)

| File | Purpose |
| --- | --- |
| `app/controllers/api/internal/transactions_controller.rb` | REST endpoints for held transactions (server-side, for v2→v1 calls) |
| `app/serializers/api/internal/transaction_serializer.rb` | JSON:API serializer |
| `config/routes.rb` | Routes: `/api/internal/transactions` |
| `app/clients/v2/transaction.rb` | Wraps gem's `TransactionClient` pointed at V2 |
| App-specific location (service object, module) | `v2_transaction` helper |

---

## Key Design Decisions

### 1. Thread-per-transaction with main AR pool

PG transactions are connection-bound. AR connections are thread-bound. Each held transaction gets its own `Thread` that checks out a connection from the main AR pool and holds it inside `ActiveRecord::Base.transaction { ... }` for the transaction's lifetime.

Why main pool (not dedicated): AR model methods like `Hotel.create!` call `ActiveRecord::Base.connection`, which returns the current thread's connection from the main pool. A dedicated pool's connections wouldn't be used by standard model calls. The Manager enforces a concurrency limit (default 10) to prevent pool starvation.

**Both apps' AR pool sizes should be increased by `max_concurrent`.**

### 2. SAVEPOINT per operation

In PG, after an error in a transaction, all subsequent commands fail. Each API operation within the held transaction runs inside `ActiveRecord::Base.transaction(requires_new: true)` (a SAVEPOINT). If the operation fails, the SAVEPOINT rolls back but the outer transaction stays alive. The error response tells the caller the transaction is still open.

### 3. Operation queue pattern

When a request arrives with `X-Transaction-ID`, the controller wraps its DB work in a block. The `TransactionAware` concern pushes this block onto the held transaction's operation queue. The held thread pops it, executes it (AR calls use the held thread's connection), and pushes the result back. The request thread blocks until complete.

```text
Request Thread                    Held Transaction Thread
     |                                    |
     |-- push(block, result_q) ---------> |
     |                                    | SAVEPOINT
     |                                    | block.call  <- AR uses this thread's connection
     |                                    | RELEASE SAVEPOINT
     | <-------- result_q.push(result) -- |
     |                                    |
```

Only one operation in-flight at a time per transaction (serialized via queue).

### 4. Full atomicity via commit ordering

All local AND remote work runs inside the transaction helper block. The remote app commits first (end of block), then the caller's `ActiveRecord::Base.transaction` auto-commits.

- If remote commit fails → exception → caller rolls back. **Consistent.**
- If caller's local commit fails after remote committed → inconsistency. **Extremely unlikely** (local PG commit after all validation passed). Accept this risk.

### 5. `with_headers` for transaction ID propagation

`json_api_client` provides `SomeResource.with_headers(hash) { ... }` using `Thread.current` storage — thread-safe. The helper wraps API calls in this block with `"X-Transaction-ID" => tx.id`.

---

## Orphaned Transactions

Transactions are in-memory (per-process). There is no persistent state to get stale:

| Scenario | What happens |
| --- | --- |
| Client abandons (no commit/rollback) | In-process reaper thread auto-rollbacks after timeout |
| Server process crashes/killed | PG connection drops, PG auto-rollbacks. Clean. |
| Server process hangs | K8s liveness probe kills pod → same as crash |
| Network partition during commit | Client gets timeout; remote may or may not have committed |

Since state is per-process, a rake-task sweeper can't see held transactions in another process. The reaper thread IS the sweeper.

**Observability:**

- Health endpoint: `GET /api/internal/{ns}/transactions` returns count of active held transactions
- Manager logs creation, commit, rollback, and reaper events at info/warn level

---

## API Contract

| Method | Path | Purpose | Response |
| --- | --- | --- | --- |
| `POST` | `/api/internal/{ns}/transactions` | Create held transaction | 201 |
| `GET` | `/api/internal/{ns}/transactions` | List active (monitoring) | 200 |
| `GET` | `/api/internal/{ns}/transactions/:id` | Check status | 200 |
| `PATCH` | `/api/internal/{ns}/transactions/:id/commit` | Commit | 200 |
| `PATCH` | `/api/internal/{ns}/transactions/:id/rollback` | Rollback | 200 |

(`{ns}` = `core` in v2, omitted in v1)

### Create request

```json
{
  "data": {
    "type": "transactions",
    "attributes": {
      "timeout_seconds": 30
    }
  }
}
```

### Create response (201)

```json
{
  "data": {
    "type": "transactions",
    "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "attributes": {
      "state": "open",
      "timeout_seconds": 30,
      "expires_at": "2026-02-19T10:30:30Z"
    }
  }
}
```

### Error response with transaction meta

When an API call within a held transaction fails:

```json
{
  "errors": [{"status": "422", "detail": "Name can't be blank"}],
  "meta": {
    "transaction_id": "abc-123",
    "transaction_rolled_back": false
  }
}
```

- `transaction_rolled_back: false` = SAVEPOINT rolled back, transaction alive. Caller can continue.
- `transaction_rolled_back: true` = whole transaction gone (e.g., expired).

### Status codes

- **429** when concurrency limit reached
- **410** when transaction expired
- **404** when transaction not found

---

## Integration Patterns

### v2 (with PrivateInteraction)

```ruby
# components/tour/app/private/tour/builder/hotels/create_hotel.rb
def execute
  ActiveRecord::Base.transaction do
    v1_transaction do
      # V1 remote work (inside v1's held PG transaction)
      create_v1_hotel!
      create_v1_room_types!

      # V2 local work (inside v2's AR transaction)
      @hotel = Builder::Hotel.new(attributes)
      merge_errors_and_rollback(@hotel, unless: :save)
      # If save fails -> ActiveRecord::Rollback -> v1_transaction catches -> v1 rolls back
    end
    # v1 commits here (still inside v2's transaction)
  end
  # v2 commits here
  @hotel
end
```

The `v1_transaction` helper (on `PrivateInteraction`) handles create/commit/rollback of the remote transaction and sets the `X-Transaction-ID` header for all V1 API calls within the block.

### v1 (without PrivateInteraction)

v1 doesn't use interactions or the Core gem. The `v2_transaction` helper lives wherever v1 puts shared service logic:

```ruby
class SyncAvailableRooms
  include V2TransactionHelper  # or however v1 organizes this

  def call(bundle_id, rooms_data)
    ActiveRecord::Base.transaction do
      v2_transaction do
        rooms_data.each do |room_data|
          V2::Tour::Builder::AvailableRoom.create!(room_data)
        end

        bundle = AvailableBundle.find(bundle_id)
        bundle.update!(synced_at: Time.current)
      end
    end
  end
end
```

### Server-side controller (either app)

Include the gem's `TransactionAware` concern and wrap DB work:

```ruby
class HotelsController < BaseController
  include JsonapiToolbox::Controller::TransactionAware

  def create
    attributes = validate_data(
      required_attributes: %w[name],
      permitted_attributes: %w[admin_note supplier_id]
    )

    hotel = with_transaction_context do
      Hotel.create!(attributes)
    end

    return unless hotel  # with_transaction_context rendered an error
    render_jsonapi(hotel, status: :created)
  end
end
```

`with_transaction_context` checks for `X-Transaction-ID`. If present, the block executes on the held transaction's thread. If absent, the block executes normally.

---

## Implementation Sequence

### Phase 1: Gem — server-side transaction holding

1. `JsonapiToolbox::Transaction::HeldTransaction` (thread, connection, queue, timeout, SAVEPOINT)
2. `JsonapiToolbox::Transaction::Manager` (singleton, reaper, concurrency limit)
3. `JsonapiToolbox::Transaction::Errors`
4. `JsonapiToolbox::Controller::TransactionAware` concern
5. Configuration module
6. Gem tests

### Phase 2: Gem — client-side

1. `JsonapiToolbox::Client::TransactionClient` (create, commit, rollback via Faraday)
2. Gem tests

### Phase 3: Wire up in each app

**v2:**
1. `TransactionsController` + serializer + routes (server-side)
2. `V1::Transaction` client + `v1_transaction` helper (client-side)
3. Include `TransactionAware` in `Core::API::Internal::BaseController`
4. Increase AR pool size
5. Integration specs

**v1:**
1. `TransactionsController` + serializer + routes (server-side)
2. `V2::Transaction` client + `v2_transaction` helper (client-side)
3. Include `TransactionAware` in internal API base controller
4. Increase AR pool size
5. Integration specs

### Phase 4: Adopt in real interactions

1. Refactor v2's `CreateHotel`, `UpdateHotel`, etc. to use `v1_transaction`
2. Refactor v1's equivalent services to use `v2_transaction`
3. Remove compensating-action code

---

## Safety Measures

- **Timeout**: Default 30s, configurable per-transaction, server-side max cap (60s)
- **Concurrency limit**: Default 10 held transactions per process, returns HTTP 429 when exceeded
- **Reaper thread**: Runs every 5s in Manager, rolls back expired transactions
- **Pool sizing**: Increase AR pool by `max_concurrent` in both apps
- **Logging**: All lifecycle events logged for debugging and monitoring
