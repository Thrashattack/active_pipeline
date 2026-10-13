# frozen_string_literal: true

require_relative "lib/active_pipeline/version"

Gem::Specification.new do |spec|
  spec.name          = "active_pipeline"
  spec.version       = ActivePipeline::VERSION
  spec.authors       = ["Carlos (Thrashattack) Cunha"]
  spec.email         = ["henrique2092@gmail.com"]

  spec.summary       = "Transparent PostgreSQL pipeline batching for ActiveRecord."
  spec.description   = "Implements Go-channel-like write batching for Rails and Sidekiq using PostgreSQL pipeline mode, " \
                       "with per-statement error isolation."
  spec.homepage      = "https://github.com/thrashattack/active_pipeline"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files         = Dir["lib/**/*.rb", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "concurrent-ruby", "~> 1.1"
  spec.add_dependency "pg", ">= 1.3"
end
