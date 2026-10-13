# frozen_string_literal: true

require "concurrent"
require "active_record"
require "pg"

require_relative "active_pipeline/version"
require_relative "active_pipeline/payload"
require_relative "active_pipeline/worker"
require_relative "active_pipeline/adapter_extension"

module ActivePipeline
  class Error < StandardError; end

  # Raised in the caller thread when +wait_timeout+ elapses before the worker
  # resolved the statement. The statement may still be committed afterwards.
  class TimeoutError < Error; end

  # ActiveSupport::Notifications event emitted once per (database, table) group
  # flushed by the worker. Payload: :table, :size, :rounds, :failed.
  BATCH_EVENT = "batch.active_pipeline"

  @mutex = Mutex.new

  class << self
    # Master switch. When false every write goes straight through ActiveRecord.
    attr_accessor :enabled

    # How long the worker keeps collecting statements after the first one arrives.
    attr_accessor :batch_window_ms

    # Upper bound of statements flushed in a single pipeline.
    attr_accessor :max_batch_size

    # Seconds a caller waits for its statement to be resolved (nil waits forever).
    attr_accessor :wait_timeout

    def configure
      yield self
    end

    def start!
      @mutex.synchronize do
        @worker = Worker.new.tap(&:start!) unless @worker&.running?
      end
    end

    def stop!
      @mutex.synchronize do
        @worker&.stop!
        @worker = nil
      end
    end

    def running?
      !!@worker&.running?
    end

    # Runs the block with the pipeline disabled for the current thread/fiber.
    def bypass
      previous = Thread.current[:active_pipeline_bypass]
      Thread.current[:active_pipeline_bypass] = true
      yield
    ensure
      Thread.current[:active_pipeline_bypass] = previous
    end

    def bypassed?
      !!Thread.current[:active_pipeline_bypass]
    end

    # Hands a payload to the running worker. Returns false when nothing is
    # running so the caller can fall back to a regular, synchronous write.
    def enqueue(payload) # :nodoc:
      !!@worker&.enqueue(payload)
    end
  end

  self.enabled = true
  self.batch_window_ms = 50
  self.max_batch_size = 500
  self.wait_timeout = nil
end

ActiveSupport.on_load(:active_record_postgresqladapter) do
  prepend ActivePipeline::AdapterExtension
end
