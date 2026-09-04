require 'jade'

module JadeSql
  # jade-sql's half of the compiler: an interface it derives and a check it
  # runs, both registered through `Jade::Extensions`.
  module Compiler
    Type = Jade::Type
    Symbol = Jade::Symbol
    Results = Jade::Results
    Ok = Jade::Ok
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

require_relative 'compiler/errors'
require_relative 'compiler/assignable'
require_relative 'compiler/columns'
require_relative 'compiler/selectable'

Jade::Extensions.register_deriver('jade-sql', JadeSql::Compiler::Assignable)
Jade::Extensions.register_deriver('jade-sql', JadeSql::Compiler::Selectable)
Jade::Extensions.register_check('jade-sql', :call, JadeSql::Compiler::Columns)
