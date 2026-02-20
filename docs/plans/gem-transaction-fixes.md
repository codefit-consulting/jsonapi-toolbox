# Brief: jsonapi-toolbox Transaction Fixes

This brief is for the `jsonapi-toolbox` gem. It covers bugs and design changes needed in the transaction feature (`lib/jsonapi_toolbox/transaction/` and `lib/jsonapi_toolbox/client/transaction_client.rb`).

---

## 1. Bug: `timeout_seconds` is ignored — always uses `max_timeout` (60s)

### Symptom

From the v1 console:
```ruby
txn = txn_client.create(timeout_seconds: 30)
# => {"timeout_seconds"=>60, ...}  ← always 60, regardless of what's requested
```

### Root cause

In `Manager#create`:
```ruby
timeout = [timeout_seconds || config.default_timeout, config.max_timeout].min
```

This is correct in isolation, but the value passed in may be nil if the v2 `TransactionsController` fails to extract it from the JSON:API request body. Investigate whether `params.dig(:data, :attributes, :timeout_seconds)` actually receives the value when the TransactionClient POSTs it. Also check:

- Is the JSON:API parameter parser registered correctly in the receiving app?
- Does `connection.post(path, body.to_json)` send the body correctly, or does Faraday need `f.request :json` middleware to encode it?
- The TransactionClient sets `Content-Type: application/vnd.api+json` but does NOT use `f.request :json` — it calls `.to_json` manually. This should be fine, but verify the body actually arrives parsed on the server side.

### Fix

Debug and fix the data flow so `timeout_seconds` passes through correctly. Add a test that creates a transaction with a custom timeout and verifies it's honoured.

---

## 2. Bug: leading slash in `transactions_path`

### Symptom

`TransactionClient` makes requests to `/transactions` (absolute path), ignoring the base URL's path component entirely.

### Root cause

```ruby
def transactions_path
  "/transactions"  # ← leading slash makes this absolute in Faraday
end
```

### Fix

```ruby
def transactions_path
  "transactions"  # relative — Faraday appends to base_url path
end
```

Already discussed with the user — just confirming it should be in this batch.

---

## 3. Design: Transactions should be proper JSON:API resources

### Current state

The `TransactionsController` in the host app manually constructs JSON responses. The `TransactionClient` returns raw hashes. Commit and rollback are custom member routes (`PATCH /transactions/:id/commit`).

### Desired state

Transactions should be full JSON:API spec resources (`id`, `type`, `attributes`, `meta`), and all lifecycle actions should map to standard JSON:API CRUD operations:

| Action | HTTP | Path | Body |
| --- | --- | --- | --- |
| Create | POST | `/transactions` | `{data: {type: "transactions", attributes: {timeout_seconds: 30}}}` |
| Show | GET | `/transactions/:id` | — |
| Commit | PATCH | `/transactions/:id` | `{data: {type: "transactions", id: "...", attributes: {state: "committed"}}}` |
| Rollback | PATCH | `/transactions/:id` | `{data: {type: "transactions", id: "...", attributes: {state: "rolled_back"}}}` |
| ~~Rollback~~ | DELETE | `/transactions/:id` | — (alternative: DELETE = rollback) |
| List | GET | `/transactions` | — |

This means commit and rollback become a standard PATCH (update) with a `state` attribute, rather than custom endpoints. The controller dispatches on the requested state value.

### Changes needed

**In the gem:**

1. **`HeldTransaction#as_json`** — Already returns `{id:, state:, timeout_seconds:, expires_at:, created_at:}`. This is good. Ensure it works as a serializable object for jsonapi-serializer.

2. **`TransactionClient`** — Replace `commit(id)` and `rollback(id)` with a generic `update(id, state:)`, or keep them as convenience methods that call update internally:
   ```ruby
   def commit(id)
     update(id, state: "committed")
   end

   def rollback(id)
     update(id, state: "rolled_back")
   end

   def update(id, attributes)
     body = {
       data: {
         type: "transactions",
         id: id,
         attributes: attributes
       }
     }
     response = connection.patch("transactions/#{id}", body.to_json)
     handle_response(response)
   end
   ```

3. **`within_transaction`** — Should still work the same (calls `commit` / `rollback` which now go through `update`).

**In the host apps (v1 and v2):**

4. **`TransactionsController`** — Replace `commit` and `rollback` actions with an `update` action that reads the requested state from `params.dig(:data, :attributes, :state)` and dispatches accordingly:
   ```ruby
   def update
     requested_state = params.dig(:data, :attributes, :state)
     case requested_state
     when "committed"
       txn = manager.commit(params[:id])
     when "rolled_back"
       txn = manager.rollback(params[:id])
     else
       # render error: invalid state transition
     end
     render_jsonapi(txn)
   end
   ```

5. **Routes** — Simplify from custom member routes to standard update:
   ```ruby
   # Before
   resources :transactions, only: [:show, :create, :index] do
     member do
       patch :commit
       patch :rollback
     end
   end

   # After
   resources :transactions, only: [:show, :create, :index, :update]
   ```

6. **Serializer** — Both apps should use a proper JSON:API serializer for the transaction resource. The gem could provide a serializable PORO or the apps define their own serializer using `JsonapiToolbox::Serializer::Base`.

---

## 4. Check: Error responses should include JSON:API `meta` with transaction info

The `TransactionAware` concern already does this in `render_operation_error`:
```ruby
body = {
  errors: [...],
  meta: { transaction_id: txn_id, transaction_rolled_back: error.transaction_rolled_back }
}
```

Verify this is correct per JSON:API spec. Top-level `meta` is allowed alongside `errors`. The client should be able to read this meta even when the response is an error.

---

## Summary of changes

| File | Change |
| --- | --- |
| `client/transaction_client.rb` | Fix leading slash, replace commit/rollback with update-based approach, verify body encoding |
| `transaction/manager.rb` | Debug timeout_seconds passthrough |
| `transaction/held_transaction.rb` | Ensure `as_json` is serializer-friendly |
| `controller/transaction_aware.rb` | Verify meta in error responses |
