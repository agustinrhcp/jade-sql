require 'jade'

require_relative 'jade-sql/version'

Jade.extension(__FILE__)

require_relative 'jade-sql/compiler'
require_relative 'jade-sql/uuid_runtime'

# Encoded `Sql.SqlError` values (the `[tag, ...args]` shape produced
# by Jade's variant encoder). Used by `runtime.rb` to emit errors back
# across the port boundary, and by anyone stubbing the ports in tests.
module JadeSql
  module SqlErrors
    NOT_FOUND = ["NotFound"].freeze
    TOO_MANY_ROWS = ["TooManyRows"].freeze
    DEADLOCK = ["Deadlock"].freeze
    SERIALIZATION_FAILURE = ["SerializationFailure"].freeze
    STATEMENT_TIMEOUT = ["StatementTimeout"].freeze
    LOCK_TIMEOUT = ["LockTimeout"].freeze

    def self.db_error(msg)
      ["DbError", msg]
    end

    def self.not_found
      NOT_FOUND
    end

    def self.too_many_rows
      TOO_MANY_ROWS
    end

    def self.unique_violation(name)
      ["UniqueViolation", name]
    end

    def self.foreign_key_violation(name)
      ["ForeignKeyViolation", name]
    end

    def self.check_violation(name)
      ["CheckViolation", name]
    end

    def self.exclusion_violation(name)
      ["ExclusionViolation", name]
    end

    def self.not_null_violation(column)
      ["NotNullViolation", column]
    end

    def self.deadlock
      DEADLOCK
    end

    def self.serialization_failure
      SERIALIZATION_FAILURE
    end

    def self.statement_timeout
      STATEMENT_TIMEOUT
    end

    def self.lock_timeout
      LOCK_TIMEOUT
    end
  end
end

module Sql
  module Errors
    class Error < StandardError; end
    class DbError < Error; end
    class NotFound < Error; end
    class TooManyRows < Error; end
    class UniqueViolation < Error; end
    class ForeignKeyViolation < Error; end
    class CheckViolation < Error; end
    class ExclusionViolation < Error; end
    class NotNullViolation < Error; end
    class Deadlock < Error; end
    class SerializationFailure < Error; end
    class StatementTimeout < Error; end
    class LockTimeout < Error; end

    BY_TAG = {
      "DbError" => DbError,
      "NotFound" => NotFound,
      "TooManyRows" => TooManyRows,
      "UniqueViolation" => UniqueViolation,
      "ForeignKeyViolation" => ForeignKeyViolation,
      "CheckViolation" => CheckViolation,
      "ExclusionViolation" => ExclusionViolation,
      "NotNullViolation" => NotNullViolation,
      "Deadlock" => Deadlock,
      "SerializationFailure" => SerializationFailure,
      "StatementTimeout" => StatementTimeout,
      "LockTimeout" => LockTimeout,
    }.freeze
  end

  def self.raise_typed!(encoded)
    type, message = encoded
    klass = Errors::BY_TAG.fetch(type, Errors::Error)
    raise klass, message
  end
end
