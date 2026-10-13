# frozen_string_literal: true

module ActivePipeline
  # Background thread that drains the queue, groups statements per
  # (database, table) and flushes each group through a dedicated connection in
  # PostgreSQL pipeline mode.
  #
  # Every group runs as one implicit transaction: when a statement fails the
  # server rolls the whole group back, the failing statement is rejected and
  # the remaining ones are pipelined again.
  class Worker
    ABORTED = Object.new.freeze
    private_constant :ABORTED

    def initialize
      @queue = ::Queue.new
      @adapters = Concurrent::Map.new
      @thread = nil
      @pid = nil
    end

    def start!
      return if @thread

      @pid = Process.pid
      @thread = Thread.new { run_loop }
      @thread.name = "active_pipeline" if @thread.respond_to?(:name=)
    end

    # Closes the queue, lets the thread drain whatever is already queued and
    # releases the connections.
    def stop!
      return unless @thread
      # A forked child shares the parent's sockets: closing them would kill the
      # parent's sessions, so the inherited worker is simply abandoned.
      return @queue.close if forked?

      @queue.close
      @thread.join
      reject_leftovers(Error.new("ActivePipeline worker stopped"))
    end

    def running?
      !@queue.closed? && !forked? && !!@thread&.alive?
    end

    def enqueue(payload)
      return false unless running?

      @queue.push(payload)
      true
    rescue ClosedQueueError
      false
    end

    private

    def forked?
      @pid != Process.pid
    end

    def run_loop
      while (first = @queue.pop)
        process_batch(collect_batch(first))
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      reject_leftovers(e)
      raise
    ensure
      disconnect_all
    end

    def collect_batch(first)
      batch = [first]
      deadline = monotonic_now + (ActivePipeline.batch_window_ms / 1000.0)

      while batch.size < ActivePipeline.max_batch_size
        remaining = deadline - monotonic_now
        break if remaining <= 0

        payload = @queue.pop(timeout: remaining)
        break unless payload

        batch << payload
      end

      batch
    end

    def process_batch(batch)
      futures = batch.group_by(&:group_key).map do |key, items|
        Concurrent::Promises.future(key, items) { |k, i| process_group(k, i) }
      end
      futures.each(&:wait)
    ensure
      batch.each { |payload| payload.reject(Error.new("statement was not processed")) }
    end

    def process_group(key, items)
      resolutions = {}.compare_by_identity

      ActiveSupport::Notifications.instrument(BATCH_EVENT, table: key.last, size: items.size) do |event|
        run_isolated(key, items, resolutions, event)
      end
    rescue StandardError => e
      discard_adapter(key)
      items.each { |item| resolutions[item] ||= [:reject, e] }
    ensure
      # Resolve only after the instrumentation finished so subscribers always
      # observe the batch before the callers wake up.
      resolutions.each { |item, (action, value)| item.public_send(action, value) }
    end

    def run_isolated(key, items, resolutions, event)
      pending = items.dup
      rounds = 0
      failed = 0

      until pending.empty?
        rounds += 1
        results = execute_pipeline(raw_connection_for(key), pending)
        index = results.index { |result| result.is_a?(Exception) }

        if index
          failed += 1
          resolutions[pending.delete_at(index)] = [:reject, results[index]]
        elsif results.any?(ABORTED)
          raise Error, "pipeline aborted without reporting an error"
        else
          pending.zip(results) { |item, result| resolutions[item] = [:fulfill, result] }
          pending = []
        end
      end
    ensure
      event[:rounds] = rounds
      event[:failed] = failed
    end

    def execute_pipeline(conn, items)
      conn.enter_pipeline_mode
      items.each { |item| conn.send_query_params(item.sql, item.binds) }
      conn.pipeline_sync

      results = items.map { |item| convert(read_result(conn), item) }
      read_sync(conn)
      conn.exit_pipeline_mode
      results
    end

    # In pipeline mode each statement's results are terminated by a nil.
    def read_result(conn)
      last = nil
      while (result = conn.get_result)
        last = result
      end
      last
    end

    def convert(result, item)
      case result&.result_status
      when PG::PGRES_TUPLES_OK, PG::PGRES_COMMAND_OK
        value = item.operation == :insert ? ActiveRecord::Result.new(result.fields, result.values) : result.cmd_tuples
        result.clear
        value
      when PG::PGRES_PIPELINE_ABORTED
        ABORTED
      when PG::PGRES_FATAL_ERROR
        error_for(result)
      else
        raise Error, "unexpected result status #{result&.result_status.inspect} for #{item.sql}"
      end
    end

    # PG::Result#check raises the specific PG::Error subclass (UniqueViolation,
    # NotNullViolation...) with the result attached, which is what ActiveRecord
    # needs to translate it into RecordNotUnique, NotNullViolation, etc.
    def error_for(result)
      result.check
      Error.new("statement failed without an error message")
    rescue PG::Error => e
      e
    end

    # The implicit transaction commits at the sync point. An error there (e.g. a
    # deferred constraint) can't be attributed to a statement, so it is raised
    # and rejects the whole group.
    def read_sync(conn)
      result = conn.get_result
      return if result&.result_status == PG::PGRES_PIPELINE_SYNC

      result&.check
      raise Error, "pipeline sync was not acknowledged"
    end

    # Each group gets its own ActiveRecord adapter so the session is configured
    # exactly like the application's (search_path, timezone, variables...).
    def raw_connection_for(key)
      adapter = @adapters.compute_if_absent(key) do
        ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(key.first.configuration_hash)
      end
      adapter.raw_connection
    end

    def discard_adapter(key)
      adapter = @adapters.delete(key)
      adapter&.disconnect!
    rescue StandardError
      nil
    end

    def disconnect_all
      @adapters.each_key { |key| discard_adapter(key) }
    end

    def reject_leftovers(error)
      while (payload = @queue.pop(timeout: 0))
        payload.reject(error)
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
