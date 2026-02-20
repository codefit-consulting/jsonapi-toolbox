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

`with_headers` (from `json_api_client`) lets you set arbitrary headers for a block of calls — this is how the transaction system propagates `X-Transaction-ID`:

```ruby
V1::Hotel.with_headers("X-Custom" => "value") do
  V1::Hotel.create(name: "test")  # request includes X-Custom header
end
```

---

## Transactions

Cross-app atomic transactions. When one app needs to mutate multiple records in another atomically, the transaction system lets you open a real PG transaction in the remote app, perform multiple API calls within it, and commit or rollback the whole thing.

```
require "jsonapi_toolbox/transaction"
```

This is opt-in — it pulls in `json_api_client`, `singleton`, and expects `ActiveRecord` to be available (both apps already have it).

### How it works

```
Calling App                             Receiving App
                                        (held PG transaction on a dedicated thread)

V1::Transaction.create(timeout: 30) ──> Manager creates HeldTransaction
                                        Thread checks out AR connection, BEGIN
<── transaction resource (state: open)

with_headers("X-Transaction-ID: abc") {
  V1::Hotel.create(name: "Test")   ──> TransactionAware detects header
                                       Executes on held thread (SAVEPOINT)
  <── hotel resource

  V1::RoomType.create(hotel: 1)   ──> Same held transaction
  <── room_type resource
}

txn.commit!                        ──> Manager.commit → COMMIT
<── transaction resource (state: committed)
```

If anything fails, the remote transaction rolls back (explicitly or via timeout). Wrap the calling side in `ActiveRecord::Base.transaction` for full local+remote atomicity.

### Configuration

```ruby
JsonapiToolbox::Transaction.configure do |config|
  config.max_concurrent = 10      # max held transactions per process
  config.default_timeout = 30     # seconds
  config.max_timeout = 60         # server-side cap
  config.reaper_interval = 5      # seconds between reaper sweeps
end

JsonapiToolbox::Transaction.logger = Rails.logger
```

Both apps' AR pool sizes should be increased by `max_concurrent` since each held transaction holds a connection for its lifetime.

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

# 3. Route
resources :transactions, only: [:index, :show, :create, :update]
```

`TransactionsActions` provides all four actions and the serializer. `TransactionAware` provides `with_transaction_context` for your other controllers:

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

When `X-Transaction-ID` is present, the block executes on the held transaction's thread inside a SAVEPOINT. When absent, it executes normally. If an operation fails, the SAVEPOINT rolls back but the outer transaction stays alive — the caller can continue or rollback.

### Client side (calling app)

Define a resource pointing at the remote app:

```ruby
class V1::Transaction < JsonapiToolbox::Client::Transaction
  self.site = "https://v1.example.com/api/internal/"
  configure_service_token -> { ServiceToken.current }
end
```

Use it directly:

```ruby
txn = V1::Transaction.create(timeout_seconds: 30)

V1::Hotel.with_headers("X-Transaction-ID" => txn.id) do
  V1::Hotel.create(name: "Test")
  V1::RoomType.create(hotel_id: 1, name: "Suite")
end

txn.commit!   # PATCH /transactions/:id with state: "committed"
```

Or use the convenience wrapper that handles commit/rollback and header propagation:

```ruby
V1::Transaction.within_transaction(timeout_seconds: 30) do |txn|
  V1::Hotel.create(name: "Test")
  V1::RoomType.create(hotel_id: 1, name: "Suite")
end
# commits on success, rolls back on any exception
```

For full local+remote atomicity:

```ruby
ActiveRecord::Base.transaction do
  V1::Transaction.within_transaction(timeout_seconds: 30) do
    # Remote work (inside V1's held PG transaction)
    V1::Hotel.create(name: "Test")

    # Local work (inside our AR transaction)
    local_record.save!
  end
  # V1 commits here (still inside our transaction)
end
# We commit here
```

### Safety

- **Timeout**: Each transaction expires after `timeout_seconds` (capped by `max_timeout`). The reaper thread automatically rolls back expired transactions.
- **Concurrency limit**: Returns HTTP 429 when `max_concurrent` is reached. Prevents AR connection pool starvation.
- **Process crash**: PG drops the connection, PG auto-rolls back. No orphaned state.
- **Monitoring**: `GET /transactions` lists active held transactions. The manager logs all lifecycle events.

### API contract

All transaction lifecycle operations use standard JSON:API CRUD:

| Action | Method | Path | Body |
|--------|--------|------|------|
| Create | POST | `/transactions` | `{data: {type: "transactions", attributes: {timeout_seconds: 30}}}` |
| Show | GET | `/transactions/:id` | |
| List | GET | `/transactions` | |
| Commit | PATCH | `/transactions/:id` | `{data: {type: "transactions", id: "...", attributes: {state: "committed"}}}` |
| Rollback | PATCH | `/transactions/:id` | `{data: {type: "transactions", id: "...", attributes: {state: "rolled_back"}}}` |

Error responses within a held transaction include metadata:

```json
{
  "errors": [{"status": "422", "detail": "Name can't be blank"}],
  "meta": {
    "transaction_id": "abc-123",
    "transaction_rolled_back": false
  }
}
```

`transaction_rolled_back: false` means the SAVEPOINT rolled back but the transaction is still alive. `true` means the whole transaction is gone (e.g., expired).

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

Transaction-specific errors are under `JsonapiToolbox::Transaction::Errors`:

| Error | HTTP | When |
|-------|------|------|
| `NotFoundError` | 404 | Transaction ID not found |
| `ExpiredError` | 410 | Transaction timed out |
| `ConcurrencyLimitError` | 429 | `max_concurrent` held transactions reached |
| `OperationError` | 422/500 | A block executed within a held transaction raised |
