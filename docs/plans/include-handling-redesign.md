# Plan: Include handling redesign

> Status: built and committed to master on 2026-10-04 as version 0.5.0. It
> replaced an earlier include-handling rewrite that was never released.

## Rationale

Include handling has two jobs. It decides which `?include=` paths a client may
request, and it eager-loads what those paths need, so that serializing the
response runs no further queries.

The gem does the first job by expanding each serializer's `allow_includes`
declarations into a list of every allowed path. In one application that uses
the gem, 51 serializers expand to 2,638 path strings, yet every one of them is a
walk over the 147 relationships those serializers declare. The `recursive:`
option keeps the declarations short, but the expansion behind it causes the
problems that a review found in October 2026. Cycles have to be cut somewhere,
and each cutting rule tried was either order-dependent or grew combinatorially.
The list has to be cached, which brings invalidation, thread-safety and
inheritance bugs. A typo becomes one more string in a long list; that
application had nine declarations that could never work.

The gem does the second job through a separate mapping. `define_include_override`
maps API relationships onto associations, and nests deeper includes under the
first key of its hash. Each action must also call `build_activerecord_includes`
and pass the result to its finder. In the same application, 8 of the 13
controllers that render JSON:API never did.

This plan gives both jobs to one walk. For each request, the gem follows the
requested paths through the serializers one segment at a time. It checks each
segment and records what to preload as it goes. `render_jsonapi` then preloads
the records it is about to serialize. The gem never lists the possible paths,
so cycles need no rule beyond a depth limit, and nothing derived needs caching.

## How a request is handled

Take this request:

```text
GET /hotels/42?include=supplier,room_types.rates
```

First, the controller parses the include list into a tree:

```ruby
{ supplier: {}, room_types: { rates: {} } }
```

Second, `validate_includes` walks the tree from HotelSerializer. At each segment
it checks three things: the serializer has a relationship with that name, the
serializer allows it to be included, and the path is within the depth limit.
The first segment that fails produces a 400 that names it.

Third, `render_jsonapi` preloads one level at a time:

1. For the hotels, ActiveRecord preloads `supplier` and `room_types`. It also
   preloads `brand` and `city`, because HotelSerializer declares that its
   `display_name` attribute reads both.
2. For the room types, it preloads `rates`, an association whose scope reads
   `Current.season`.
3. For the rates, it preloads `currency`, because RateSerializer declares that
   its `price_label` attribute reads it.

Each association costs one query, as it would in a single nested `includes`
call. Serializing then runs no queries for anything the request included, and
it reuses the records the gem loaded.

## What happens behind the scenes

`.includes` is usually called on the query that loads the primary records:

```ruby
hotels = Hotel.where(id: 42).includes(:supplier, :brand, :city, room_types: { rates: :currency }).to_a
```

When that query runs, ActiveRecord loads the hotels and then hands them to
`ActiveRecord::Associations::Preloader`, which runs one query per association
and attaches the results to each record. The same class can be called directly
on records that are already loaded, so the gem can preload one level at a time:

```ruby
# Rails 7 and later. Before Rails 7 the call is
# ActiveRecord::Associations::Preloader.new.preload(records, associations).
def preload(records, associations)
  ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
end

hotels = Hotel.where(id: 42).to_a
# SELECT "hotels".* FROM "hotels" WHERE "hotels"."id" = 42

preload(hotels, [ :supplier, :brand, :city, :room_types ])
# SELECT "suppliers".* FROM "suppliers" WHERE "suppliers"."id" = 1
# SELECT "brands".* FROM "brands" WHERE "brands"."id" = 1
# SELECT "cities".* FROM "cities" WHERE "cities"."id" = 1
# SELECT "room_types".* FROM "room_types" WHERE "room_types"."hotel_id" = 42

room_types = hotels.flat_map(&:room_types) # already loaded, so no query
preload(room_types, :rates)
# SELECT "rates".* FROM "rates" WHERE "rates"."season_id" = 1 AND "rates"."room_type_id" IN (1, 2)

rates = room_types.flat_map(&:rates)
preload(rates, :currency)
# SELECT "currencies".* FROM "currencies" WHERE "currencies"."id" = 1
```

These are the same seven queries that the single `includes` call runs, in the
same order, and reading the hotels, room types, rates and currencies afterwards
runs none. The scoped `rates` association reads `Current.season` at the moment
it is preloaded, which is why the action must set it before rendering. The gem
collects each level's records by asking every serializer relationship for them.
For a plain association, that means reading what was just loaded, as
`flat_map(&:room_types)` does here.

Working level by level matters when a relationship is a method. Between two
preload calls, the gem can step outside ActiveRecord, ask the serializer for a
relationship's records, and carry on from whatever it returns:

```ruby
price_lists = hotels.map(&:current_price_list).compact.uniq # a plain method, so no query
preload(price_lists, :entries)
# SELECT "price_list_entries".* FROM "price_list_entries" WHERE "price_list_entries"."price_list_id" = 1
```

A single `includes` hash cannot express that step:
`Hotel.includes(current_price_list: :entries)` raises
`ActiveRecord::AssociationNotFoundError`, because Hotel has no association named
`current_price_list`.

`Preloader` is marked `:nodoc:` in both Rails 4.2 and Rails 8.1, so it is
internal API, even though the class documents its arguments. Its interface
also changed in Rails 7.0. The gem therefore calls it from one method in
`preloader.rb`, and the test plan covers both forms. The example above ran on
Rails 8.1 and on Rails 4.2 with Ruby 2.6, with the same queries on both, except
that Rails 4.2 writes `IN (1)` where Rails 8.1 writes `= 1`.

## Who may include what

A serializer that says nothing lets clients include any of its relationships:

```ruby
class HotelSerializer
  include JsonapiToolbox::Serializer::Base

  belongs_to :supplier
  has_many :room_types
end
```

A serializer that names relationships with `allow_includes` allows only those:

```ruby
class PublicHotelSerializer
  include JsonapiToolbox::Serializer::Base

  belongs_to :supplier
  has_many :room_types

  allow_includes :room_types
end
```

A path may continue through any relationship that the serializer at that point
allows. `room_types.rates` therefore works whenever RoomTypeSerializer allows
`rates`, and no declaration ever describes a whole path. The only limit on
depth, and the only rule that cycles need, is `max_include_depth`, which
defaults to eight segments:

```ruby
JsonapiToolbox::Serializer.configure do |config|
  config.max_include_depth = 8
end
```

An internal API can declare no `allow_includes` at all.

## How each relationship loads

By default, a relationship loads through the ActiveRecord association that
jsonapi-serializer reads for it: the association with the relationship's name,
or its `object_method_name` if it sets one. APIs often present a different view
of the world from the domain model, and each common difference has a
declaration.

### Typed views of one polymorphic association

A Comment has one polymorphic `commentable`, which the API presents as two
typed relationships, `post` and `photo`. A model method filters by type:

```ruby
class Comment < ApplicationRecord
  belongs_to :commentable, polymorphic: true

  def post
    commentable if commentable.is_a?(Post)
  end
end
```

The relationship names its association with `association:`:

```ruby
belongs_to :post, association: :commentable
belongs_to :photo, association: :commentable
```

The gem preloads `commentable` once. To find the records for deeper includes, it
then asks each relationship for its records, so the type filter decides which
records continue.

### Records behind an intermediate record

Sometimes the API hides a record in the middle. Suppose a hotel's room types
belong to its `property`. An array names the chain:

```ruby
has_many :room_types, association: [ :property, :room_types ] do |hotel|
  hotel.property.room_types
end
```

Includes requested below the relationship are preloaded under the last step of
the chain.

### Views scoped by the request

An association whose scope reads a per-request setting needs no declaration:

```ruby
has_many :rates, -> { where(season: Current.season) }
```

Because the gem preloads inside `render_jsonapi`, the action must set
`Current.season` before it renders.

### Relationships that are not associations

A relationship can be a plain method, such as one that returns
`Current.price_list` or runs its own query. `association: false` marks it:

```ruby
has_one :current_price_list, serializer: :price_list, association: false
```

For these, the gem asks the serializer for the related records and preloads
whatever the request names below them. Applications that used to split such
paths off the include list and preload them by hand no longer need to.

When an ActiveRecord model has no association for a relationship that declares
nothing, the gem raises `IncludeDeclarationError`, naming the relationship and
both remedies. A method-backed relationship therefore cannot quietly fall back
to one query per record.

### Parents that are not ActiveRecord records

A serializer can render a value object that wraps records, such as an
`ImportRun = Data.define(:id, :hotel)` returned by an action that starts an
import. There are no associations to preload on it, so the gem asks the
serializer for `import_run.hotel` and continues from what it gets. A controller
no longer has to rewrite `hotel.` include paths onto the wrapped record.

### Associations that the related records need

`preload:` adds associations to the related records whenever the relationship
is included. It is relative to those records:

```ruby
has_many :room_types, preload: { bed_types: :configurations }
```

### Associations that an attribute needs

`preload_for_attributes` declares what an attribute reads, on the serializer
that owns the attribute:

```ruby
class HotelSerializer
  include JsonapiToolbox::Serializer::Base

  attribute :display_name
  preload_for_attributes :display_name, [ :brand, :city ]
end
```

The gem adds these wherever the serializer's records are serialized, including
the primary records of a request without `?include=`. Many extra preloads that
an app attaches to a relationship today really serve an attribute of the related
records, and belong here.

## Fetched records are reused

When the gem asks a relationship for its records, it keeps the answer for the
rest of the render, and serialization reads the relationship from there. This
matters for two reasons. The records the gem preloaded are the same objects the
serializer sees, even when the relationship builds new objects on every call,
as a method that runs its own query does. It also stops jsonapi-serializer
fetching a relationship twice, once for linkage and once for included records.

The store is a hash keyed by relationship and record identity. `render_jsonapi`
passes it to the serializer in `params`, and a small module prepended to
`FastJsonapi::Relationship` consults it in two methods.
`fetch_associated_object` returns stored records. `fetch_id` covers
relationships with a block, for which jsonapi-serializer computes linkage ids
by calling the block again; the apps' fork of jsonapi-serializer does this for
nested includes too. Outside `render_jsonapi` and `Preloader.call` the module
does nothing. Both methods are the same in jsonapi-serializer 2.2 and the fork.

## Errors

A request error is a 400 that names the failing segment and what was possible
there:

```text
Invalid include "room_types.foo": "foo" is not a relationship of room_types. Includable here: hotel, rates, bed_types.
```

Messages name the JSON:API type, which clients know, instead of the
serializer class.

The same error covers a relationship that `allow_includes` excludes, a path
deeper than `max_include_depth`, and a path that continues below a relationship
whose serializer is chosen per record.

A declaration problem found while serving a request raises
`IncludeDeclarationError`, which surfaces as a 500. Examples are a relationship
whose serializer class does not exist, and an association named by
`association:` that the model lacks.

## Checking declarations in CI

`JsonapiToolbox::Serializer.verify_includes!(serializers)` reports every problem
it can find without loading records:

- `allow_includes` names that are not relationships;
- relationships whose serializer class cannot be resolved;
- `preload_for_attributes` names that are not attributes.

It cannot check `association:` chains, because a serializer does not know its
model class. A later addition can check them when the app names the model for
each root serializer (see [Later](#later)).

## What leaves the public API

These go:

- the `recursive:` and `prefix:` options and dotted entries in `allow_includes`;
- `allowed_includes`, `build_activerecord_includes` and `define_include_override`;
- `on_dropped_include`, `DisallowedIncludeError` and the
  `include_dropped.jsonapi_toolbox` event. A requested path can no longer be
  dropped, because the same walk both checks and loads it.

These stay: `allow_includes` (now a list of relationship names),
`preload_for_attributes`, `verify_includes!` and
`JsonapiToolbox::Serializer.configure`.

## Gem changes

- `lib/jsonapi_toolbox/serializer/include_handling.rb` holds the declarations:
  `allow_includes`, the `association:` and `preload:` options, which it reads
  by overriding `has_many`, `has_one` and `belongs_to` (the `lazy_` helpers call
  these), `preload_for_attributes` and `verify_includes!`.
- A new `lib/jsonapi_toolbox/serializer/include_tree.rb` parses the include list
  and walks it, producing either a 400 or a tree of load steps.
- A new `lib/jsonapi_toolbox/serializer/preloader.rb` runs the steps against
  records and holds the fetch store. It hides the two ActiveRecord preloader
  APIs: `ActiveRecord::Associations::Preloader.new.preload(records, tree)`
  before Rails 7, and `Preloader.new(records:, associations:).call` from Rails 7.
- `lib/jsonapi_toolbox/controller/validation.rb`: `validate_includes` walks the
  tree, and `validate_sparse_fieldsets` finds each type's serializer along the
  requested tree.
- `lib/jsonapi_toolbox/controller/rendering.rb`: `render_jsonapi` preloads
  before it serializes, unless the action passes `preload: false`.
- `lib/jsonapi_toolbox/errors.rb`: `InvalidIncludeError` carries the failing
  path, its last segment and the relationships includable there, and
  `DisallowedIncludeError` goes.

The working tree already contains `preload_for_attributes`,
`Serializer.configure`, the `verify_includes!` entry point, the ActiveRecord
query-count spec and the sparse-fieldset fix. Those carry over. The rest of the
tree's include handling is replaced.

## Edge cases

- Several parents share a related record. Preloading per level still costs one
  query per association, and the gem removes duplicates by identity before it
  descends.
- A level holds records of several classes, as under a polymorphic association.
  The gem groups the records by class before it checks associations, and
  continues only with the records each relationship returns.
- A relationship has an `if:` condition. The gem skips the parents for which
  the condition is false.
- An action renders a record that a service object has just saved. ActiveRecord's
  preloader leaves an association that is already loaded alone (checked in
  ActiveRecord 8.1), so stale in-memory associations would be served. Such
  actions should reload the record before rendering it.
- An action has already eager-loaded everything it renders.
  `render_jsonapi(..., preload: false)` skips the gem's preloading.
- A collection is very large. The `IN` lists are as long as they would be with
  `includes`.
- jsonapi-serializer treats a resource as a collection only when it is an
  `Enumerable`, and a Rails 4.2 relation is not one. The preloader asks the
  serializer's own `is_collection?`, honouring the `is_collection:` option, so
  the two always agree; a Rails 4.2 app passes `is_collection: true` or an
  array, as it must for serialization anyway.
- A relationship with a block but no `serializer:` has its serializer chosen
  per record, so nothing below it can be checked or preloaded. Such paths are
  rejected with a 400 until the relationship names its serializer.
- Nothing shared is computed lazily, so threads cannot race.

## Test plan

Gem specs:

- parsing, depth, the open default and the allowlist;
- every error message;
- each loading form: the default, a renamed association, a chain,
  `association: false`, value-object parents, typed views over mixed classes,
  `preload:` and attribute preloads;
- the fetch store, including a relationship that builds new objects on every
  call.

The ActiveRecord specs count queries: one for each association at each level,
and none while serializing. The suite also runs on Ruby 2.6 with Rails 4.2 in a
scratch gem directory, because the gemspec still supports both, and that run
exercises the older preloader call. ActiveRecord 4.2 needs the sqlite3 1.3 gem,
which builds on Ruby 2.6. It runs against the apps' fork of jsonapi-serializer
as well, because the fork serializes nested includes differently.

## Migrating an application

Include handling is still greenfield work, so it changes without a deprecation
path. An application moving from 0.4 makes these changes, and should keep its
own detailed notes in its own repository.

1. Decide what clients may include. For an internal API, delete every
   `allow_includes`. Otherwise reduce each one to a plain list of relationship
   names: paths compose automatically, so `recursive:` and dotted entries are
   unnecessary, and a prefixed name is simply another relationship.

2. Convert each `define_include_override`:

   ```ruby
   # Before: the API name differs from the association.
   define_include_override :post, { commentable: {} }
   # After:
   belongs_to :post, association: :commentable

   # Before: the records sit behind an intermediate record, plus extras.
   define_include_override :room_types, { property: { room_types: { bed_types: {} } } }
   # After:
   has_many :room_types, association: [ :property, :room_types ], preload: :bed_types

   # Before: not an association.
   define_include_override :current_price_list, false
   # After:
   has_one :current_price_list, serializer: :price_list, association: false
   ```

   When an override's extras exist because an attribute of the related records
   reads them, move them to `preload_for_attributes` on that serializer instead,
   so they apply on every path. Extras that are relative to the parent record
   cannot be expressed with `preload:`; move them to the serializer whose
   attribute needs them.

3. Delete calls to `build_activerecord_includes` and the `includes(...)` they
   fed, together with any code that rewrites include paths for wrapper objects
   or computed relationships. Keep plain reloads that exist for freshness, and
   set any per-request context, such as `Current` attributes, before calling
   `render_jsonapi`.

4. Without an allowlist every relationship is includable, so every relationship
   needs a serializer class that resolves.

5. Add one spec that calls `JsonapiToolbox::Serializer.verify_includes!` on
   every serializer after `Rails.application.eager_load!`.

6. Check the include lists that clients send against `max_include_depth`, and
   compare query counts for representative requests before and after.

## Later

- Batch loaders. A `loader: ->(parents, params) { ... }` option would return the
  related records for all parents from one query and fill the fetch store. A
  relationship backed by a method that queries once per record needs one to
  avoid that cost.
- Model-aware verification. Given the model class for each root serializer,
  `verify_includes!` could follow ActiveRecord reflections alongside the
  serializers and check every `association:` chain.
- Includes below a polymorphic relationship, checked for each record against the
  serializer that jsonapi-serializer chooses for it.
- Skipping an attribute's preloads when a sparse fieldset leaves the attribute
  out.

## Decisions

- 2026-10-03: Attribute preloads are declared with the separate
  `preload_for_attributes` macro.
- 2026-10-04: The gem walks each request through the serializers and no longer
  lists every allowed path. Permission is an allowlist per serializer, and a
  serializer without one allows every relationship.
- 2026-10-04: This plan supersedes the earlier choices about cycles ("stop at
  repeats"), dropped includes (a warning, with an opt-in raise) and unusable
  entries (excluded with a warning).
- 2026-10-04: Application-specific migration notes live in each application's
  repository, because the gem is public.
- 2026-10-04: `render_jsonapi` preloads by default, and an action opts out with
  `preload: false`.
- 2026-10-04: An ActiveRecord parent whose model has no association for a
  relationship that declares nothing raises `IncludeDeclarationError`. The gem
  never falls back to fetching such a relationship one record at a time.
- 2026-10-04: The gem reuses the records it fetched while preloading through a
  prepend on `FastJsonapi::Relationship#fetch_associated_object`, active only
  while the params carry the gem's store. Wrapping relationship blocks was
  rejected because it changes how jsonapi-serializer finds related ids and
  serializer classes. Building it showed that `fetch_id` needs the same
  treatment for relationships with a block, so the prepend covers both.
