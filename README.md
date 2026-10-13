# ActivePipeline

Transparent Go-channel-like transaction batching for ActiveRecord. 

ActivePipeline buffers outgoing SQL queries from your Puma/Sidekiq threads and executes them simultaneously per-model using PostgreSQL Pipeline mode. (Recommended for Sidekiq only, or high multi-threaded Puma servers)

## Installation & Setup
Add to your Gemfile:
```ruby
gem 'active_pipeline'
```

## Configure via Initializer (config/initializers/active_pipeline.rb):

```ruby
ActivePipeline.configure do |config|
  config.batch_window_ms = 50 # Default 50ms batching window
  config.enabled = true
end
```

## To enable inside Sidekiq (Recommended):

```ruby
Sidekiq.configure_server do |config|
  config.on(:startup)  { ActivePipeline.start! }
  config.on(:shutdown) { ActivePipeline.stop! }
end
```

## Tradeoffs & Explicit Transactions
Because ActivePipeline transparently diverts INSERT, UPDATE, and DELETE queries to a background worker, it breaks traditional ActiveRecord multi-statement transactions.

If you have a strict transactional boundary where multiple records MUST commit together or roll back, you must bypass the pipeline:

```ruby
ActivePipeline.bypass do
  User.transaction do
    user.save!
    post.save!
  end
end
```