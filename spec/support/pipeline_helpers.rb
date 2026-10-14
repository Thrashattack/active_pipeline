# frozen_string_literal: true

module PipelineHelpers
  # Collects the payload of every batch.active_pipeline event fired while the
  # block runs. Events come from the worker thread, hence the thread-safe array.
  def capture_batches
    events = Concurrent::Array.new
    subscriber = ActiveSupport::Notifications.subscribe(ActivePipeline::BATCH_EVENT) do |*, payload|
      events << payload.dup
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # Runs the block in +count+ threads released at the same time, returning each
  # thread's value or the exception it raised.
  def concurrently(count)
    barrier = Concurrent::CyclicBarrier.new(count)
    threads = Array.new(count) do |index|
      Thread.new do
        barrier.wait
        ActiveRecord::Base.connection_pool.with_connection { yield index }
      rescue StandardError => e
        e
      end
    end
    threads.map(&:value)
  end

  def worker
    ActivePipeline.instance_variable_get(:@worker)
  end

  def worker_backend_pids
    worker.instance_variable_get(:@adapters).values.map { |adapter| adapter.raw_connection.backend_pid }
  end
end
