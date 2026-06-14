Gem::Specification.new do |s|
  s.name        = 'jade-sql'
  s.version     = '0.1.0'
  s.summary     = 'Type-safe SQL extension for Jade'
  s.authors     = ['agustin']
  s.files       = Dir['lib/**/*']
  s.require_paths = ['lib']
  s.required_ruby_version = '~> 3.4'

  s.add_dependency 'jade'

  # The query/mutation builders and schema generator are pure Jade/Ruby and
  # need none of the below. They are required only by the opt-in
  # `jade-sql/runtime` (ActiveRecord-backed Task ports) — see README.
  #   - activerecord
  #   - pg (or another adapter)
end
