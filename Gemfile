# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  # Integration testing dependencies
  gem 'gemini-ai'
  gem 'ruby-anthropic'
  gem 'ruby_llm'
  gem 'ruby-openai'
  gem 'vcr'
  gem 'webmock'
  # gem "openai", github: "openai/openai-ruby", branch: "main"
  gem 'byebug'
  # The official OpenAI SDK declares required_ruby_version >= 3.3.0, but this
  # gem still supports 3.2 (see required_ruby_version in the gemspec) and CI
  # tests that floor. Nothing in the suite needs it -- spec_helper's
  # `require 'openai'` resolves to ruby-openai, which also ships lib/openai.rb
  # -- it is only used by examples/openai_ruby_mcp.rb. So skip it on 3.2
  # rather than letting a dev-only dependency dictate the library's floor.
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3')
    gem 'openai', github: 'openai/openai-ruby', branch: 'main'
  end
end
