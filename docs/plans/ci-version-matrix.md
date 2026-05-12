# Plan: CI version matrix

> **Status:** stub. Not yet picked up. Owner unassigned.

## Rationale

The gemspec advertises broad compatibility:

```ruby
spec.required_ruby_version = ">= 2.6"
spec.add_dependency "activesupport", ">= 4.2"
spec.add_dependency "actionpack",    ">= 4.2"
spec.add_dependency "json_api_client", [">= 1.22", "< 2.0"]
```

In practice the gem is consumed by two apps with very different stacks:

| App | Ruby | Rails | Faraday |
|---|---|---|---|
| v1 | 2.7 | 4.2 | 0.17.6 |
| v2 | 3.3.8 | 7.2.2 | 2.14.1 |

The gem's own `Gemfile.lock` resolves to AS 8.1.2 + Faraday 2.14.1, so the
test suite only ever exercises the modern end of the supported range.
Compatibility with the v1 stack is currently only verified by code
inspection — which is how the Faraday 1.x-vs-2.x divergence in
`clone_middleware_stack` slipped through (see commit 70f687b).

## What this plan should produce

- An Appraisals file (or equivalent) pinning at least these matrix points:
  - **Min**: Ruby 2.7, Rails 4.2, json_api_client 1.22, Faraday 0.17
  - **Mid**: Ruby 3.1, Rails 6.1, Faraday 1.x
  - **Max**: Ruby 3.3, Rails 7.2, Faraday 2.x
- A GitHub Actions workflow that runs `bundle exec rspec` against each
  combination on push / PR.
- A README badge and a short "Supported versions" section that points at
  whatever the CI matrix actually proves green, so the gemspec floors and
  reality can't drift apart silently.

## Out of scope

- Dropping the AS 4.2 / Ruby 2.7 floor. That's a separate decision, and
  should be made *after* we know how much of the test suite passes against
  it.
- Splitting the gem into a v1-compatible release line vs. a modern release
  line. If the matrix turns out to be cheap to maintain, we don't need to.

## Triggering events that should bump this up the priority list

- Any future bug report from v1 that turns out to be a Faraday/Rails-version
  regression we shipped without noticing.
- Any change that adds a new runtime dependency or raises an existing floor.
