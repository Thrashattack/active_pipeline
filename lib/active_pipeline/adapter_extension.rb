# frozen_string_literal: true

module ActivePipeline
  # Prepended to ActiveRecord::ConnectionAdapters::PostgreSQLAdapter. Diverts
  # INSERT/UPDATE/DELETE statements to the worker when it is safe to do so and
  # falls back to the stock implementation otherwise.
  module AdapterExtension
    def exec_insert(sql, name = nil, binds = [], pk = nil, sequence_name = nil, returning: nil)
      return super unless pipeline_write? && (use_insert_returning? || pk == false)

      insert_sql, insert_binds = sql_for_insert(sql, pk, binds, returning)
      pipeline_execute(:insert, insert_sql, name, insert_binds) { super }
    end

    def exec_update(sql, name = nil, binds = [])
      return super unless pipeline_write?

      pipeline_execute(:update, sql, name, binds) { super }
    end

    def exec_delete(sql, name = nil, binds = [])
      return super unless pipeline_write?

      pipeline_execute(:delete, sql, name, binds) { super }
    end

    private

    # A materialized transaction means this connection already sent BEGIN (and
    # may hold row locks), so the statement has to run on this very connection:
    # pipelining it would escape the transaction or deadlock against it.
    def pipeline_write?
      ActivePipeline.enabled &&
        ActivePipeline.running? &&
        !ActivePipeline.bypassed? &&
        !current_transaction.materialized?
    end

    def pipeline_execute(operation, sql, name, binds)
      casted_binds = type_casted_binds(binds)
      payload = Payload.new(operation: operation, sql: sql, binds: casted_binds, db_config: pool.db_config)

      return yield unless ActivePipeline.enqueue(payload)

      log(sql, name, binds, casted_binds) do
        payload.wait(ActivePipeline.wait_timeout)
      rescue PG::Error => e
        raise translate_exception_class(e, sql, binds)
      end
    end
  end
end
