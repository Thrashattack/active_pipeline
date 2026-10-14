# ActivePipeline

[![CI](https://github.com/thrashattack/active_pipeline/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/thrashattack/active_pipeline/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/Thrashattack/active_pipeline/badge.svg?branch=main)](https://coveralls.io/github/thrashattack/active_pipeline?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.txt)

Transparent, Go-channel-like write batching for ActiveRecord on PostgreSQL.

ActivePipeline intercepts the `INSERT`, `UPDATE` and `DELETE` statements issued by your
threads (Sidekiq workers, multi-threaded Puma), buffers them for a short window and flushes
them per table in a single round trip using
[PostgreSQL pipeline mode](https://www.postgresql.org/docs/current/libpq-pipeline-mode.html).
Each caller thread blocks until its own statement is resolved, so application code
keeps the usual synchronous API: `create!` still returns a persisted record with its id,
and `update_all` still returns the affected row count.

If one statement in a batch fails, only that caller gets the error. The rest of the batch
is retried and committed.

## Table of contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [Transactions and tradeoffs](#transactions-and-tradeoffs)
- [Instrumentation](#instrumentation)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)

## How it works

```
 Sidekiq threads                       ActivePipeline worker                 PostgreSQL
 ───────────────                       ─────────────────────                 ──────────
 User.create!  ─┐                    ┌─ group "users" ─ pipeline ─────────▶  BEGIN (implicit)
 User.create!  ─┼─▶ queue ─ window ──┤    INSERT, INSERT, UPDATE ...          ...
 Post.update!  ─┘   (IVar per call)  └─ group "posts" ─ pipeline ─────────▶  SYNC / COMMIT
       ▲                                         │
       └──────────── results / errors ───────────┘
```

1. A write on a PostgreSQL connection is wrapped in a payload and pushed onto a queue. The
   calling thread then waits on a `Concurrent::IVar`.
2. A background worker takes the first statement, keeps collecting for `batch_window_ms`
   (or until `max_batch_size`), and groups the batch by database and table.
3. Each group is sent through its own dedicated connection in pipeline mode as one implicit
   transaction. Groups run in parallel.
4. If a statement fails, PostgreSQL rolls the whole group back. ActivePipeline rejects
   the failing statement and pipelines the remaining ones again.
5. Callers wake up with the same values and the same exception classes
   (`ActiveRecord::RecordNotUnique`, `ActiveRecord::NotNullViolation`, ...) that ActiveRecord
   would have produced.

## Requirements

- Ruby >= 3.2
- ActiveRecord >= 7.1 with the PostgreSQL adapter
- `pg` >= 1.3, built against libpq >= 14 (pipeline mode)
- PostgreSQL >= 14

## Installation

Add the gem to your application's Gemfile:

```ruby
gem "active_pipeline"
```

Then run:

```sh
bundle install
```

## Usage

The pipeline only diverts writes while the worker is running. Start it in the processes
where batching pays off. Sidekiq is the recommended place:

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.on(:startup)  { ActivePipeline.start! }
  config.on(:shutdown) { ActivePipeline.stop! }
end
```

In processes that never call `start!` (web servers, consoles, rake tasks), every write goes
straight through ActiveRecord as usual.

`stop!` drains the statements that are already queued before closing its connections. If
the process forks after `start!`, call `start!` again in the child; the child never reuses
the parent's worker.

To force a block of code to skip the pipeline:

```ruby
ActivePipeline.bypass do
  Order.transaction do
    order.save!
    order.line_items.each(&:save!)
  end
end
```

## Configuration

```ruby
# config/initializers/active_pipeline.rb
ActivePipeline.configure do |config|
  config.enabled         = true # master switch
  config.batch_window_ms = 50   # how long to keep collecting after the first statement arrives
  config.max_batch_size  = 500  # statements per flush
  config.wait_timeout    = nil  # seconds a caller waits before ActivePipeline::TimeoutError (nil = forever)
end
```

| Option            | Default | Description |
|-------------------|---------|-------------|
| `enabled`         | `true`  | When `false`, all writes use the regular ActiveRecord path. |
| `batch_window_ms` | `50`    | Maximum latency added to a write while the worker collects a batch. |
| `max_batch_size`  | `500`   | Upper bound of statements flushed in one pipeline. |
| `wait_timeout`    | `nil`   | Raises `ActivePipeline::TimeoutError` in the caller after this many seconds. The statement is **not** cancelled and may still commit afterwards. |

## Transactions and tradeoffs

Pipelined statements run on the worker's connections, not on the connection of the calling
thread. Keep the following in mind:

- **Materialized transactions are respected.** If the current connection already started a
  transaction (it ran any query inside `transaction do ... end`, including the `SELECT` of a
  uniqueness validation or a `lock`), the write runs on that connection as usual. This keeps
  rollbacks and row locks correct and avoids deadlocking against your own transaction.
- **Lazy transactions are not.** A `transaction` block whose first statement is a write
  gets that write committed by the pipeline independently. A later `raise
  ActiveRecord::Rollback` will not undo it. Use `ActivePipeline.bypass` or read something
  first when several writes must commit atomically.
- **Connections.** The worker opens one connection per database and table it writes to.
  Size `max_connections` on the server accordingly.
- **Ordering.** Statements are applied in queue order within a table. There is no ordering
  guarantee between different tables in the same batch. A single thread is never affected,
  because each caller waits for its own statement to finish.
- **Bulk `insert_all`/`upsert_all`** and raw `execute` calls are not pipelined.

## Instrumentation

Pipelined statements are still logged and instrumented as `sql.active_record`. In addition,
the worker emits one `batch.active_pipeline` event per flushed group:

```ruby
ActiveSupport::Notifications.subscribe("batch.active_pipeline") do |event|
  event.payload # => { table: "users", size: 42, rounds: 2, failed: 1 }
end
```

`rounds` is the number of pipelines needed to isolate failures. `failed` is the number of
statements that were rejected.

## Development

You need a running PostgreSQL. The specs connect using `DB_HOST`, `DB_PORT`, `DB_NAME`,
`DB_USER` and `DB_PASSWORD`. The defaults are `localhost`, `5432`, `active_pipeline_test`,
`postgres` and `postgres`.

```sh
createdb active_pipeline_test
bundle install
bundle exec rake # runs the specs
```

Every run writes a coverage report to `coverage/index.html`. On CI it also produces
`coverage/lcov.info`, which is uploaded to Coveralls.

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/thrashattack/active_pipeline.

1. Fork the repository
2. Create your feature branch (`git checkout -b my-feature`)
3. Add specs for your change and make sure `bundle exec rake` passes
4. Open a pull request

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
