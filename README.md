# jsonapi-toolbox

Controller, serializer, and client tooling for JSON:API apps built on [jsonapi-serializer](https://github.com/jsonapi-serializer/jsonapi-serializer) and [json_api_client](https://github.com/JsonApiClient/json_api_client). Supports Rails 4.2+.

```ruby
# Gemfile
gem "jsonapi-toolbox", git: "https://github.com/jmchambers/jsonapi-toolbox.git"
```

The core gem (`require "jsonapi_toolbox"`) gives you controllers, serializers, and error handling. The client module (`require "jsonapi_toolbox/client"`) gives you a base class for consuming remote JSON:API services. The transaction module (`require "jsonapi_toolbox/transaction"`) adds cross-app atomic transactions — opt-in, since it pulls in additional dependencies.

---

## Controllers

### ResourceController

A ready-made base controller with JSON:API document validation, serializer auto-detection, include/fieldset validation, and error rendering. Inherits from `ActionController::API`.

```ruby
class Api::V1::HotelsController < JsonapiToolbox::ResourceController
  def index
    hotels = Hotel.all
    render_jsonapi(hotels)
  end

  def show
    hotel = Hotel.find(params[:id])
    render_jsonapi(hotel)
  end

  def create
    attributes = validate_data(
      required_attributes: %w[name],
      permitted_attributes: %w[admin_note star_rating],
      permitted_relationships: %w[supplier]
    )

    hotel = Hotel.create!(attributes)
    render_jsonapi(hotel, status: :created)
  end
end
```

If you need to inherit from your own `ApplicationController` (for auth, middleware, etc.), compose the concerns directly:

```ruby
class Api::Internal::BaseController < ApplicationController
  include JsonapiToolbox::Controller::SerializerDetection
  include JsonapiToolbox::Controller::Validation
  include JsonapiToolbox::Controller::DataValidation
  include JsonapiToolbox::Controller::Rendering

  rescue_from JsonapiToolbox::Errors::InvalidIncludeError,
              JsonapiToolbox::Errors::InvalidFieldsError,
              JsonapiToolbox::Errors::SerializerNotFoundError,
              JsonapiToolbox::Errors::ValidationError,
              JsonapiToolbox::Errors::UnpermittedAttributeError,
              JsonapiToolbox::Errors::UnpermittedRelationshipError,
              JSONAPI::Parser::InvalidDocument,
              ActiveRecord::RecordNotFound,
              with: :render_jsonapi_error
end
```

### Concerns

Each concern can be used independently:

**SerializerDetection** — auto-detects the serializer class from the controller name. `PackagesController` finds `PackageSerializer` in the same namespace, with a fallback one level up (so `Api::V1::PackagesController` will try `Api::V1::PackageSerializer` then `Api::PackageSerializer`).

**Validation** — registers `before_action` hooks that validate the JSON:API document structure on `create`/`update`, validate `?include=` against the serializer's `allowed_includes`, and validate `?fields[type]=` against the serializer's declared attributes.

**DataValidation** — the `validate_data` method (alias for `extract_and_validate_jsonapi_data`). Extracts attributes and relationships from the JSON:API request body, checks required/permitted fields, and converts relationship data to foreign keys (`{data: {type: "suppliers", id: "5"}}` becomes `supplier_id: "5"`).

```ruby
attributes = validate_data(
  required_attributes: %w[name check_in_date],
  permitted_attributes: %w[notes],
  required_relationships: %w[supplier],
  permitted_relationships: %w[region]
)
# => {"name" => "...", "check_in_date" => "...", "notes" => "...", "supplier_id" => "5", "region_id" => "3"}
```

Has-many relationships are converted to `_ids`: `{data: [{type: "tags", id: "1"}, {type: "tags", id: "2"}]}` becomes `tag_ids: ["1", "2"]`.

**Rendering** — `render_jsonapi(resource, options = {})` serializes using the auto-detected (or explicit) serializer, respecting validated includes and sparse fieldsets. `render_jsonapi_error(error)` renders JSON:API-compliant error responses for all the gem's error types, plus `ActiveRecord::RecordNotFound` and `ActiveInteraction::InvalidInteractionError` (if loaded).

### Railtie

Automatically registers the `application/vnd.api+json` MIME type and configures the JSON:API parameter parser for both Rails 4.x and 5+.

---

## Serializers

Include `JsonapiToolbox::Serializer::Base` in your serializers to get type auto-detection, include handling, and lazy relationships:

```ruby
class Api::V1::HotelSerializer
  include JsonapiToolbox::Serializer::Base

  attributes :name, :star_rating, :admin_note

  lazy_belongs_to :supplier, serializer: Api::V1::SupplierSerializer
  lazy_has_many :room_types, serializer: Api::V1::RoomTypeSerializer

  allow_includes :supplier, :room_types, recursive: true
end
```

### Type auto-detection

The JSON:API `type` is derived from the serializer class name automatically. `HotelSerializer` becomes `"hotels"`, `RoomTypeSerializer` becomes `"room_types"`. Override with `set_type :custom_name` if needed.

### Include handling

`allow_includes` declares which relationships can be requested via `?include=`. The `Validation` concern validates incoming requests against this list.

```ruby
# Simple includes
allow_includes :supplier, :room_types

# Recursive — walks the relationship tree through child serializers
allow_includes :room_types, recursive: true
# If RoomTypeSerializer also has `allow_includes :allocations, recursive: true`,
# then "room_types.allocations" is automatically allowed.

# Prefixed — for polymorphic or aliased relationships
allow_includes :room_types, prefix: :standard
# Allows "standard_room_types"
```

**Include overrides** — when the API relationship name doesn't match the ActiveRecord association:

```ruby
class HotelSerializer
  include JsonapiToolbox::Serializer::Base

  lazy_has_many :room_types, serializer: RoomTypeSerializer

  allow_includes :room_types, recursive: true

  # The API calls it "room_types" but AR needs to eager-load through a scope
  define_include_override :room_types, { available_room_types: :allocations }
end
```

`build_activerecord_includes` translates a list of API include paths into a nested hash suitable for `ActiveRecord::QueryMethods#includes`:

```ruby
HotelSerializer.build_activerecord_includes(["room_types", "room_types.allocations"])
# => { available_room_types: { allocations: {} } }
```

### Lazy relationships

Convenience wrappers around jsonapi-serializer's relationship declarations with `lazy_load_data: true`:

```ruby
lazy_has_many :room_types, serializer: RoomTypeSerializer
lazy_has_one :address, serializer: AddressSerializer
lazy_belongs_to :supplier, serializer: SupplierSerializer
```

Relationship data is only serialized when the relationship is included via `?include=`, avoiding N+1 queries for unused relationships.

---

## Client

A thin wrapper around `json_api_client` for consuming remote JSON:API services. Require it separately:

```ruby
require "jsonapi_toolbox/client"
```

Define resource classes that point at the remote service:

```ruby
class V1::Hotel < JsonapiToolbox::Client::Base
  self.site = "https://v1.example.com/api/internal/"
  configure_service_token -> { ServiceToken.current }
end

class V1::RoomType < JsonapiToolbox::Client::Base
  self.site = "https://v1.example.com/api/internal/"
  configure_service_token -> { ServiceToken.current }
end
```

Then use them like ActiveRecord:

```ruby
hotels = V1::Hotel.where(name: "Test").includes(:room_types).all
hotel = V1::Hotel.create(name: "New Hotel", supplier_id: 5)
hotel.update_attributes(name: "Updated")
V1::Hotel.find(42).destroy
```

`configure_service_token` accepts a string or a callable (proc/lambda). The token is injected as an `X-Service-Token` header on every request via Faraday middleware.

`with_headers` (from `json_api_client`) lets you set arbitrary headers on a single resource class for a block of calls:

```ruby
V1::Hotel.with_headers("X-Custom" => "value") do
  V1::Hotel.create(name: "test")  # request includes X-Custom header
end
```

Note that `with_headers` is scoped to the class it's called on — `V1::Hotel.with_headers(...)` does **not** set headers on requests made by `V1::RoomType` inside the block. For cross-class header propagation (as the transaction system needs for `X-Transaction-ID`), use a Faraday middleware that reads from `Thread.current`; that's what `within_transaction` does internally.

### Persistent Connections

The client uses Faraday's `:net_http_persistent` adapter for HTTP keep-alive by default. Keep-alive underpins **multi-worker transaction affinity**: when the receiving app runs under Puma/Unicorn/Passenger with multiple workers, a held transaction lives in memory on one specific worker process, and every request inside a `within_transaction` block must land on that same worker. A persistent TCP connection stays pinned to the worker that accepted it, so reusing one socket for the whole block is what makes this work.

Affinity is scoped **per-transaction**, not per-resource-class. Inside a `within_transaction` block, `Transaction.within_transaction` builds one dedicated Faraday connection (own socket, own `Net::HTTP::Persistent` pool), stashes it on the current thread, and every `JsonapiToolbox::Client::Base` subclass used in the block routes through it. On block exit, the connection is closed and the thread-local is cleared. Outside the block, each subclass keeps its own connection, so normal traffic continues to load-balance across workers.

- **Faraday 0.x:** The adapter is built-in. No extra dependencies needed.
- **Faraday 2.x:** The adapter was extracted. Add to your Gemfile:

  ```ruby
  gem "faraday-net_http_persistent", "~> 2.1"
  ```

  And require it during app boot (e.g. in an initializer):

  ```ruby
  require "faraday/net_http_persistent"
  ```

To disable persistent connections (e.g. in test environments):

```ruby
JsonapiToolbox::Client.configure do |config|
  config.persistent_connections = false
end
```

With persistent connections disabled, remote transactions will still work under a single-worker server, but will fail intermittently under multi-worker deployments.

---

## Transactions

Cross-app atomic transactions. When one app needs to mutate multiple records in another atomically, the transaction system lets you open a real PG transaction in the remote app, perform multiple API calls within it, and commit or rollback the whole thing.

```
require "jsonapi_toolbox/transaction"
```

This is opt-in — it pulls in `json_api_client`, `singleton`, and expects `ActiveRecord` to be available (both apps already have it).

### How it works

```
Calling App                                Receiving App
                                           (held PG transaction on a dedicated thread)

V1::Transaction.within_transaction do
  # <no remote call yet — nothing on the wire>

  V1::Hotel.create(name: "Test")    ─┬──> POST /transactions (materialise)
                                     │    Manager creates HeldTransaction,
                                     │    thread checks out AR connection, BEGIN
                                     │ <── transaction (state: open)
                                     │
                                     └──> POST /hotels  (X-Transaction-ID: abc)
                                          TransactionAware detects header,
                                          executes on held thread (SAVEPOINT)
                                     <──  hotel resource

  V1::RoomType.create(hotel: 1)       ──> POST /room_types (same held txn)
                                     <──  room_type resource
end                                   ──> PATCH /transactions/abc  state=committed
                                          Manager.commit → COMMIT
                                     <──  transaction (state: committed)
```

The `POST /transactions` only fires on the first resource call inside the block — see [Laziness](#client-side-calling-app) below. If the block makes no remote calls, nothing is sent. If anything fails, the remote transaction rolls back (explicitly, or by being reaped once the caller stops heartbeating). Wrap the calling side in `ActiveRecord::Base.transaction` for full local+remote atomicity.

While the block is open, the client runs an **automatic heartbeat** (a background thread bound to the transaction lifecycle — you never touch it) that pings the receiver so it knows the caller is still alive. The receiver reaps a held transaction **only** when the caller stops heartbeating (crash / OOM-kill / network partition) or blows an optional runaway `hard_cap_ttl` — not on a blind wall-clock deadline. An **operation in flight also counts as liveness**: a single op that runs longer than the lease won't be reaped while it's executing (its heartbeat is serialised behind it on the pinned connection anyway), only if it blows the `hard_cap_ttl`. See [Timeout model](#timeout-model-crash-only-lease--heartbeat).

### Configuration

Everything is defaulted — an app only sets what it wants to override. The gem
**never reads ENV itself**; if you want env-driven values, read them in your own
initializer and assign them here (ENV or literals — your choice).

```ruby
JsonapiToolbox::Transaction.configure do |config|
  # Shared
  config.max_concurrent         = 10    # max held transactions per process

  # Receiver policy — authoritative when this app *hosts* a transaction
  config.lease_ttl_default      = 30    # lease granted when the client requests none
  config.lease_ttl_min          = 10    # clamp floor for a client-requested lease
  config.lease_ttl_max          = 120   # clamp ceiling for a client-requested lease
  config.hard_cap_ttl_default   = 3600  # absolute max lifetime (s from creation); nil disables entirely
  config.hard_cap_ttl_max       = 3600  # clamp ceiling for a requested hard_cap_ttl; nil = no ceiling
  config.reaper_scan_interval   = 5     # seconds between reaper sweeps

  # Client policy — used when this app *initiates* a transaction
  config.heartbeat_divisor      = 3     # heartbeats per lease window (tolerate divisor-1 misses)
  config.heartbeat_min_interval = 2     # floor, so a small lease can't cause a heartbeat storm
  config.requested_lease_ttl    = nil   # default lease to request; also per-txn (nil → server default)
  config.requested_hard_cap_ttl = nil   # default hard_cap_ttl to request; also per-txn (nil → server default)
end

JsonapiToolbox::Transaction.logger = Rails.logger
```

**Most apps set none of the timing values.** Everything that governs *how long a
transaction stays open and when it's reaped* — the lease, heartbeat, hard-cap,
and reaper timings — has defaults tuned for the common case and rarely needs
fine-tuning. There's no budget to size and no timeout to guess: a live caller is
proven alive by its automatic heartbeat, and a dead one is reaped a few seconds
after it stops, so the model is self-correcting. Reach for these only to
*tighten* (e.g. a shorter `lease_ttl_default` for faster crash detection), and
even then rarely.

**The two you scale to your app** are capacity settings, not timings — size them
to what your app does and how many DB connections it can support:

- **`max_concurrent`** — how many held transactions a process supports at once.
  Each holds an AR connection for its lifetime, so raise it (and your app's AR
  pool by the same amount) for a busy receiver. Bounded by the DB connections you
  can afford, not by any time budget.
- **`hard_cap_ttl_max`** — the longest lifetime a caller is *allowed* to request.
  Default 1 h is generous; lower it to be stricter, or raise/nil it only if you
  genuinely have a long operation that needs to ask for more.

**You do not need matching constants across the two apps — they negotiate.** On
`POST /transactions` the client sends its `requested_lease_ttl` /
`requested_hard_cap_ttl` (or nothing); the receiver clamps them to its own
policy, stores the granted values, and **echoes them in the create response**.
The client reads the granted `lease_ttl` back and sets its heartbeat cadence to
`max(granted_ttl / heartbeat_divisor, heartbeat_min_interval)`. Whichever app is
the *receiver* for a given call is the sole authority on reaping, so a
v1↔v2 mismatch is impossible.

**About `hard_cap_ttl`.** It is the **only** hard cutoff, and it's a runaway
sanity check, not a routine deadline: default ~1 h, **settable to `nil` to
disable entirely**. Your app should never need — or ask — to hold a single
remote transaction open anywhere near this long; if it trips, something is
genuinely wrong (a runaway that keeps heartbeating), not merely slow. A caller
can request a tighter per-transaction `hard_cap_ttl` — sized to the work — via
`requested_hard_cap_ttl` (in `configure` for an app-wide default, or per call on
`within_transaction`), clamped only by the receiver's `hard_cap_ttl_max`.

**Static vs. per-transaction.** Only two values can be set **per transaction**,
by passing them to `within_transaction`: `requested_lease_ttl` and
`requested_hard_cap_ttl` (each falls back to its configured default, then the
server's). Everything else is **process-wide static config** set in `configure`.

```ruby
# per-transaction override: request a tighter runaway cap than the receiver's default
V1::Transaction.within_transaction(requested_hard_cap_ttl: 120) do
  V1::Hotel.create(name: "Test")
end
```

The split is deliberate: the receiver-policy values (`max_concurrent`, the
`lease_ttl_*` clamps, `hard_cap_ttl_*`, `reaper_scan_interval`) are the
*receiver's* authority — one caller can't dynamically change how another process
reaps or how many slots it has; it can only *request* a lease / hard-cap and take
whatever the receiver clamps it to. The heartbeat cadence (`heartbeat_divisor`,
`heartbeat_min_interval`) is client-wide behaviour, not varied per call (it's
derived from the granted lease anyway).

> **Deployment note:** raise each app's AR pool size by `max_concurrent`, since
> each held transaction holds a connection for its lifetime.

### Forking servers (Puma cluster, Unicorn, etc.)

The transaction manager runs a background **reaper thread** that periodically rolls back transactions whose caller has gone silent (missed heartbeats past its lease) or blown the `hard_cap_ttl`. In Ruby, threads do **not** survive `fork(2)` — only the calling thread is copied to each child. That has a sharp consequence for any forking app server that boots Rails in the parent process before forking workers.

**Symptom of a missing reaper:** every `POST /transactions` eventually returns 429. Workers happily create transactions but nothing ever cleans up reapable ones, so the held pool fills to `max_concurrent` and stays there until the process restarts. You will see no `Reaping transaction` log lines.

**For Puma cluster mode with `preload_app!`** (the common production setup), call `start_reaper!` from `on_worker_boot`:

```ruby
# config/puma.rb
preload_app!

on_worker_boot do
  # If you have AR:
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord::Base)

  JsonapiToolbox::Transaction::Manager.instance.start_reaper!
end
```

That's it. The gem self-heals on the next `create` if the reaper somehow isn't running, but installing it in `on_worker_boot` ensures the reaper is up from the moment the worker starts accepting requests rather than starting on the first transaction creation.

**For Puma in single mode** (no cluster, no preload), or any non-forking server: start the reaper from a regular Rails initializer and you're done.

```ruby
# config/initializers/jsonapi_toolbox_transaction.rb
JsonapiToolbox::Transaction::Manager.instance.start_reaper!
```

**Other forking servers (Unicorn, Pitchfork, Passenger).** Same idea: the reaper must be (re)started inside each worker after the fork. Use the after-fork hook for your server (`after_fork` in Unicorn, `PhusionPassenger.on_event(:starting_worker_process)` in Passenger, etc.) to call `start_reaper!`.

**Diagnostic.** If you suspect a stuck pool in any environment, `GET /api/internal/transactions` returns the full held list. A pool sitting at `max_concurrent` with old `created_at` timestamps and no `Reaping transaction` log lines indicates a reaper that isn't running. (`expires_at` in the list is a rough display hint only — actual reaping is driven by heartbeat freshness, not that field.)

### Server side (receiving app)

Three things to wire up:

```ruby
# 1. Include TransactionAware in your base controller
class Api::Internal::BaseController < ApplicationController
  include JsonapiToolbox::Controller::TransactionAware
end

# 2. Transactions controller — one line
class Api::Internal::TransactionsController < Api::Internal::BaseController
  include JsonapiToolbox::Controller::TransactionsActions
end

# 3. Routes — note the extra heartbeat route
resources :transactions, only: [:index, :show, :create, :update]
post "transactions/:id/heartbeat", to: "transactions#heartbeat"
```

`TransactionsActions` provides all the actions (including `heartbeat`) and the serializer. The heartbeat route is required for the crash-only timeout model — the client's automatic heartbeat POSTs to it to prove liveness; without it, held transactions would be reaped as soon as the lease elapsed. `TransactionAware` provides `with_transaction_context` for your other controllers:

```ruby
class Api::Internal::HotelsController < Api::Internal::BaseController
  def create
    attributes = validate_data(
      required_attributes: %w[name],
      permitted_attributes: %w[star_rating]
    )

    hotel = with_transaction_context do
      Hotel.create!(attributes)
    end

    return unless hotel
    render_jsonapi(hotel, status: :created)
  end
end
```

When `X-Transaction-ID` is present, the block executes on the held transaction's thread inside a SAVEPOINT, and the op itself refreshes the transaction's liveness (a real op counts as a heartbeat). When absent, it executes normally. If an operation fails, the SAVEPOINT rolls back but the outer transaction stays alive — the caller can continue or rollback. If the referenced transaction was already reaped, `with_transaction_context` renders a legible reaped error (404 with `meta.transaction_reaped`) that the client turns into a typed `TransactionReaped` — see [Errors](#errors).

### Client side (calling app)

Define a resource pointing at the remote app:

```ruby
class V1::Transaction < JsonapiToolbox::Client::Transaction
  self.site = "https://v1.example.com/api/internal/"
  configure_service_token -> { ServiceToken.current }
end
```

Then use `within_transaction` to wrap a block of remote work:

```ruby
V1::Transaction.within_transaction do |txn|
  V1::Hotel.create(name: "Test")
  V1::RoomType.create(hotel_id: 1, name: "Suite")
end
# commits on success, rolls back on any exception
```

`within_transaction` handles commit/rollback, attaches `X-Transaction-ID` to every request in the block (via a Faraday middleware), pins the block to a single worker by routing all requests through one dedicated connection (see [Persistent Connections](#persistent-connections)), and runs the **automatic heartbeat** for the block's lifetime so the receiver keeps the transaction alive as long as this process is. You never manage the heartbeat thread; it starts at materialisation and is torn down on commit/rollback. Its requests are serialised with your real requests on the pinned connection, so they never race on the socket.

To request a lease and/or `hard_cap_ttl` for a transaction, pass `requested_lease_ttl:` / `requested_hard_cap_ttl:` to `within_transaction` (or set app-wide defaults in `configure`, § [Configuration](#configuration)). Both are clamped by the receiver, which echoes the grant; the heartbeat cadence follows automatically. The most common use is a tighter hard cap than the receiver's generous default, sized to the work:

```ruby
# this op only touches a handful of records — cap it at 2 min, not the receiver's ~1 h default
V1::Transaction.within_transaction(requested_hard_cap_ttl: 120) do
  V1::Hotel.create(name: "Test")
end
```

**Laziness.** `within_transaction` is lazy: no remote request is issued at block entry. The `POST /transactions` fires only on the first resource call inside the block. Blocks that make no remote calls — e.g. an interaction that wraps itself in `within_transaction` defensively but ends up with no remote-syncable data to push — cost nothing on the wire and don't consume a concurrency slot on the receiving app. Consequences:

- The yielded `txn` is a `LazyTransaction` proxy. Before materialisation, `txn.id` is `nil`, `txn.state` is `"not_opened"`, and `txn.materialized?` is `false`. Once a remote call has fired, the proxy forwards to the real underlying transaction resource.
- The lease + heartbeat start at the first remote call (materialisation), not at block entry. Long local work at the start of a block costs nothing remotely.
- Errors from `POST /transactions` (e.g. `ConcurrencyLimitError` on HTTP 429) now raise from the stack frame of your first remote call rather than from block entry. The error class is unchanged; `rescue` clauses around the block still catch it.

**Use `within_transaction`.** The raw CRUD on `V1::Transaction` (`create`, `commit!`, `rollback!`) is available for inspection and scripting, but driving a transaction by hand is error-prone: you have to set `X-Transaction-ID` on every sibling request yourself, and you get no worker affinity, so in a multi-worker deployment the sibling requests can land on a worker that has never heard of the transaction.

For full local+remote atomicity:

```ruby
ActiveRecord::Base.transaction do
  V1::Transaction.within_transaction do
    # Remote work (inside V1's held PG transaction)
    V1::Hotel.create(name: "Test")

    # Local work (inside our AR transaction)
    local_record.save!
  end
  # V1 commits here (still inside our transaction)
end
# We commit here
```

### Timeout model: crash-only lease + heartbeat

The receiver reaps a held transaction only when the caller is demonstrably gone,
not on a blind wall-clock deadline. Two independent reap reasons, surfaced
distinctly (via the typed error and the `transaction_reaped` event):

- **`lease_expired`** — the caller stopped heartbeating for longer than its
  granted `lease_ttl` (crash / OOM-kill / network partition). The normal reap.
  A real op or a heartbeat refreshes the lease, so a fan-out of hundreds of
  serial writes — or a long *quiet* local computation between two remote calls —
  is never reaped while the caller lives.
- **`hard_cap_ttl_exceeded`** — the caller is alive and still heartbeating but
  has blown the absolute `hard_cap_ttl` ceiling. A runaway. `hard_cap_ttl` is nil-able.

Worst-case reap latency is `lease_ttl + reaper_scan_interval`. The receiver uses
a **monotonic** clock, so an NTP step can't cause a false reap.

### Safety

- **Crash-only reaping**: see [Timeout model](#timeout-model-crash-only-lease--heartbeat) above.
- **Concurrency limit**: Returns HTTP 429 when `max_concurrent` is reached. Prevents AR connection pool starvation.
- **Process crash**: PG drops the connection, PG auto-rolls back. No orphaned state. The reaper then evicts the dead slot once its lease lapses.
- **Monitoring**: `GET /transactions` lists active held transactions; the manager logs all lifecycle events and emits instrumentation ([Observability](#observability)).

### API contract

All transaction lifecycle operations use standard JSON:API CRUD, plus the heartbeat endpoint:

| Action | Method | Path | Body |
|--------|--------|------|------|
| Create | POST | `/transactions` | `{data: {type: "transactions", attributes: {requested_lease_ttl: 30, requested_hard_cap_ttl: 300}}}` |
| Show | GET | `/transactions/:id` | |
| List | GET | `/transactions` | |
| Heartbeat | POST | `/transactions/:id/heartbeat` | *(empty; 204 No Content on success)* |
| Commit | PATCH | `/transactions/:id` | `{data: {type: "transactions", id: "...", attributes: {state: "committed"}}}` |
| Rollback | PATCH | `/transactions/:id` | `{data: {type: "transactions", id: "...", attributes: {state: "rolled_back"}}}` |

Create attributes are both optional: `requested_lease_ttl` and `requested_hard_cap_ttl`. Each is clamped by the receiver's policy. The create response **echoes the granted values** so the client can set its heartbeat cadence:

```json
{
  "data": {
    "type": "transactions",
    "id": "abc-123",
    "attributes": {
      "state": "open",
      "lease_ttl": 30,
      "hard_cap_ttl": 300
    }
  }
}
```

**Operation error** responses within a held transaction include metadata:

```json
{
  "errors": [{"status": "422", "title": "Name can't be blank", "detail": "Name can't be blank"}],
  "meta": { "transaction_id": "abc-123", "transaction_rolled_back": false }
}
```

`transaction_rolled_back: false` means the SAVEPOINT rolled back but the transaction is still alive. `true` means the whole transaction is gone.

**Reaped** responses (a request/heartbeat referencing an already-reaped slot) carry a `title` and a distinct `transaction_reaped` meta, so the client raises a typed `TransactionReaped` rather than a misleading generic 404:

```json
{
  "errors": [{"status": "404", "title": "Transaction abc-123 was reaped ...", "detail": "..."}],
  "meta": { "transaction_id": "abc-123", "transaction_reaped": true, "reason": "lease_expired" }
}
```

`reason` is `"lease_expired"` or `"hard_cap_ttl_exceeded"`.

### Observability

The gem emits plain [`ActiveSupport::Notifications`](https://api.rubyonrails.org/classes/ActiveSupport/Notifications.html) events (no metrics-library dependency — works on Rails 4.2), so each app can subscribe and export with whatever collector it can load. All events are namespaced `*.jsonapi_toolbox`:

| Event | Payload | Fires |
|-------|---------|-------|
| `transaction_materialized.jsonapi_toolbox` | `id, lease_ttl, hard_cap_ttl` | receiver grants a new held transaction |
| `transaction_committed.jsonapi_toolbox` | `id, op_count, duration` | commit |
| `transaction_rolled_back.jsonapi_toolbox` | `id, op_count, duration` | explicit rollback |
| `transaction_reaped.jsonapi_toolbox` | `id, reason, idle_for, age, op_count` | reaper tears a slot down |
| `transaction_operation.jsonapi_toolbox` | `transaction_id, endpoint, verb, in_txn, op_count, duration` | each op run on a held transaction |
| `rollback_failed.jsonapi_toolbox` | `transaction_id, error` | a client-side `within_transaction` rollback failed |

```ruby
# e.g. in an initializer — subscribe and forward to your metrics stack
ActiveSupport::Notifications.subscribe("transaction_reaped.jsonapi_toolbox") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  StatsD.increment("v1_sync.transaction_reaped", tags: ["reason:#{event.payload[:reason]}"])
end
```

The `transaction_reaped` event is the one unambiguous "caller died / budget blown" signal — a good thing to alert on.

---

## Errors

All errors are under `JsonapiToolbox::Errors` and rendered automatically by `render_jsonapi_error`:

| Error | HTTP | When |
|-------|------|------|
| `ValidationError` | 400 | Required attributes/relationships missing, or unpermitted fields sent |
| `InvalidIncludeError` | 400 | `?include=` contains paths not in `allowed_includes` |
| `InvalidFieldsError` | 400 | `?fields[type]=` contains attributes not on the serializer |
| `UnpermittedAttributeError` | 400 | Request body contains attributes not in `permitted_attributes` |
| `UnpermittedRelationshipError` | 400 | Request body contains relationships not in `permitted_relationships` |
| `JSONAPI::Parser::InvalidDocument` | 400 | Request body is not a valid JSON:API document |
| `SerializerNotFoundError` | 500 | Auto-detection couldn't find a serializer for the controller |
| `ActiveRecord::RecordNotFound` | 404 | Standard AR not-found (detail strips internal namespaces) |

Transaction-specific errors are under `JsonapiToolbox::Transaction::Errors` (raised on the **receiver**):

| Error | HTTP | When |
|-------|------|------|
| `NotFoundError` | 404 | Transaction ID never existed on this process |
| `ReapedError` | 404 | Transaction was reaped (caller went silent, or blew `hard_cap_ttl`); carries `reason` and renders `meta.transaction_reaped` |
| `ExpiredError` | 410 | Transaction is no longer open (already committed/rolled back) |
| `ConcurrencyLimitError` | 429 | `max_concurrent` held transactions reached |
| `OperationError` | 422/500 | A block executed within a held transaction raised |

On the **client**, a reaped-slot response is turned into a typed error you can rescue:

| Error | Base | Carries | When |
|-------|------|---------|------|
| `JsonapiToolbox::Client::TransactionReaped` | `JsonApiClient::Errors::NotFound` | `transaction_id`, `reason` | any request/heartbeat came back with `meta.transaction_reaped` |

Because `TransactionReaped` subclasses `NotFound`, existing `rescue JsonApiClient::Errors::NotFound` paths still catch it; rescue `TransactionReaped` specifically when you want the self-describing message (it names the transaction and reason instead of string-scraping the resource URL).

```ruby
begin
  V1::Transaction.within_transaction { V1::Hotel.create(name: "x") }
rescue JsonapiToolbox::Client::TransactionReaped => e
  logger.warn("remote txn #{e.transaction_id} reaped (#{e.reason}); nothing was saved")
  # nothing committed — safe to retry or surface a clear message
end
```
