require_relative 'lib/jade-sql/version'

Gem::Specification.new do |s|
  s.name        = 'jade-sql'
  s.version     = JadeSql::VERSION
  s.summary     = 'Type-safe SQL extension for Jade'
  s.description = 'Query and mutation builders, schema generation from ' \
    'db/structure.sql, and an ActiveRecord-backed runtime for the Jade ' \
    'language. Renders typed queries to (String, List(Value)) and decodes ' \
    'rows into Jade structs.'
  s.authors     = ['agustin']
  s.email       = ['agustincornu@fastmail.com']
  s.homepage    = 'https://github.com/agustinrhcp/jade-sql'
  s.license     = 'MIT'

  s.files = Dir['lib/**/*'] + Dir['docs/**/*'] + Dir['exe/*'] +
    ['README.md', 'LICENSE']
  s.bindir        = 'exe'
  s.executables   = ['jade-sql']
  s.require_paths = ['lib']
  s.required_ruby_version = '>= 3.4'

  s.metadata = {
    'source_code_uri' => 'https://github.com/agustinrhcp/jade-sql',
    'rubygems_mfa_required' => 'true',
  }

  s.add_dependency 'jade-lang', '~> 0.6.0'
end
