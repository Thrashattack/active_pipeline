# frozen_string_literal: true

module ActivePipeline
  # A single write statement waiting in the queue. The caller thread blocks on
  # +wait+ until the worker resolves it with +fulfill+ or +reject+.
  class Payload
    UNKNOWN_TABLE = "unknown"

    IDENTIFIER = /(?:"(?:[^"]|"")+"|[\w$]+)/
    TABLE_REGEX = %r{
      \A\s*(?:/\*.*?\*/\s*)*                  # leading query-log comments
      (?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+
      (#{IDENTIFIER}(?:\.#{IDENTIFIER})?)       # optionally schema-qualified
    }mix

    attr_reader :operation, :sql, :binds, :db_config, :table_name

    def self.table_name_for(sql)
      match = TABLE_REGEX.match(sql)
      match && match[1].delete('"')
    end

    def initialize(operation:, sql:, binds:, db_config:)
      @operation = operation
      @sql = sql
      @binds = binds
      @db_config = db_config
      @table_name = self.class.table_name_for(sql) || UNKNOWN_TABLE
      @ivar = Concurrent::IVar.new
    end

    def group_key
      [db_config, table_name]
    end

    def fulfill(value)
      @ivar.set(value) unless @ivar.complete?
    end

    def reject(error)
      @ivar.fail(error) unless @ivar.complete?
    end

    def resolved?
      @ivar.complete?
    end

    def wait(timeout = nil)
      value = @ivar.value!(timeout)
      raise TimeoutError, "statement was not resolved within #{timeout}s" unless @ivar.complete?

      value
    end
  end
end
