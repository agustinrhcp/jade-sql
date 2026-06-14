source 'https://rubygems.org'

gemspec

# jade isn't published yet. Track the local checkout for now; swap for a
# version (or git) dependency once the gem ships.
gem 'jade', path: '/Users/agustincornu/code/ruby/jade'

group :test do
  gem 'rspec'
  gem 'rspec-its'
  gem 'rspec-collection_matchers'
  gem 'byebug'
  gem 'diff-lcs'
  gem 'rake'

  # Opt-in runtime + Postgres integration tests.
  gem 'activerecord'
  gem 'pg'
end
