# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest", "~> 5.25"
gem "rake", "~> 13.0"
# Builds the Rust extension and, in CI, cross-compiles the platform gems.
gem "rake-compiler", "~> 1.3"
gem "rb_sys", "~> 0.9"

# Booting test/dummy needs the request stack and view layer; the gem itself
# only depends on railties + activesupport. RAILS_VERSION lets CI pin a single
# minor series so the support matrix is actually exercised.
rails_requirement = ENV["RAILS_VERSION"] ? "~> #{ENV["RAILS_VERSION"]}.0" : ">= 8.0"
gem "actionpack", rails_requirement
gem "actionview", rails_requirement
gem "railties", rails_requirement
# Images referenced from content are published through the asset pipeline
# (Q-10), so the dummy app needs the same pipeline a real Rails 8 app has.
gem "propshaft", ">= 1.0"
