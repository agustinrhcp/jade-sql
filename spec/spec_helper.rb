$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'rspec/its'
require 'rspec/collection_matchers'
require 'byebug'

require 'jade'
require 'jade/result'
require 'jade/tasks/rspec'
require 'jade/frontend/type_checking/var_gen'

# AR is a real dev dependency here, so load it (and the PG adapter, for its
# OID/Type constants) up front: the integration specs need the real classes,
# and runtime_spec's AR stubs are guarded by `unless defined?(...)`, which
# then no-op against the real lib instead of colliding with it.
require 'active_record'
require 'active_record/connection_adapters/postgresql_adapter'

Dir[File.join(__dir__, 'support/**/*.rb')].sort.each { |f| require f }

RSpec.configure do |config|
  config.include RSpec::CollectionMatchers

  config.before(:each) { Jade::Frontend::TypeChecking::VarGen.counter = 0 }

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random
  Kernel.srand config.seed
end
