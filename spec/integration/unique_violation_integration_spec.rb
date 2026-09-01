require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'
require 'jade-sql/runtime'

module Jade
  describe 'INSERT unique-violation -> Sql.UniqueViolation against Postgres', :integration do
    include_context 'with test compiler'
    include_context 'with database'

    def conn = JadeSql::TestDb.connection

    before do
      conn.execute("DROP TABLE IF EXISTS accounts")
      conn.execute(<<~SQL)
        CREATE TABLE accounts (
          id    serial PRIMARY KEY,
          email text,
          CONSTRAINT accounts_email_key UNIQUE (email)
        )
      SQL
      conn.execute("INSERT INTO accounts (email) VALUES ('dup@x.com')")

      test_compiler.require('app', <<~JADE)
module App exposing (add)

import Sql exposing (
  Assignable,
  Assignment,
  Expr,
  NoJoins,
  Pk,
  SqlError,
  Table,
  assign,
  column,
  execute,
  no_joins,
  pk,
  table,
)
import Encode
import Sql.Mutation exposing (insert)


struct Account = { email: String }


#{jade_table('accounts', { email: 'String' }, pk: 'accounts_pk')}


implements Assignable(Account) with
  to_assigns: account_assigns
end


def account_assigns(a: Account) -> List(Assignment)
  [assign("email", a.email)]
end


def accounts_pk -> Pk(AccountsCols, Int)
  pk(["id"], (v) -> { [Encode.encode(v)] })
end


def add(email: String) -> Task(Int, SqlError)
  insert(Account(email), accounts) |> execute
end
      JADE
    end

    after { conn.execute("DROP TABLE IF EXISTS accounts") }

    it 'returns UniqueViolation carrying the violated constraint name' do
      expect(App::Internal.add('dup@x.com').run)
        .to be_err(look_like("Sql::UniqueViolation", "accounts_email_key"))
    end

    it 'leaves a non-conflicting insert as Ok' do
      expect(App::Internal.add('fresh@x.com').run).to be_ok(1)
    end
  end
end
