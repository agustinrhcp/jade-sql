require 'jade'

module JadeSql
  # jade-sql's half of the compiler, registered through `Jade::Extensions`.
  module Compiler
    Type = Jade::Type
    Symbol = Jade::Symbol
    Results = Jade::Results
    Err = Jade::Err
    Lexer = Jade::Lexer
    Helpers = Jade::Frontend::TypeChecking::Constraints::Deriving::Helpers
    DerivationFailed = Jade::Frontend::TypeChecking::Error::DerivationFailed

    # The generator renames a column that collides with a jade keyword, so
    # `type_` maps back to the `type` it came from.
    def self.column_name(field)
      field
        .to_s
        .then { it.end_with?('_') ? it.delete_suffix('_') : it }
        .then { Lexer::KEYWORDS.include?(it) ? it : field.to_s }
    end
  end
end

require_relative 'compiler/assignable'

Jade::Extensions.register_deriver('jade-sql', JadeSql::Compiler::Assignable)
