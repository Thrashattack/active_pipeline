# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Statements without binds failed with `PQsendQuery not allowed in pipeline mode`.
- Reading pipeline results ignored the per-statement `nil` terminators, so batches of more than one statement failed.
- Inserts were missing `RETURNING "id"`, so created records had no primary key.
- Writes hung forever when the worker was not started, had stopped, or the process had forked.
- Worker crashes or connection failures could leave callers waiting forever; they are now always released.
- Writes inside a materialized transaction escaped it (and could deadlock on row locks); they now run on the caller's connection.
- Database errors are translated into the usual ActiveRecord classes (`RecordNotUnique`, `NotNullViolation`, ...).
- Worker connections are configured like the application's (search path, timezone, variables) and follow the model's database in multi-database setups.
- Nested `ActivePipeline.bypass` blocks restore the outer state.

### Added
- `max_batch_size` and `wait_timeout` settings.
- `batch.active_pipeline` instrumentation event; pipelined statements are logged as `sql.active_record`.
- `stop!` drains queued statements before shutting down.

### Changed
- Requires Ruby >= 3.2 and ActiveRecord >= 7.1.

## [0.1.0]

- Initial release.
