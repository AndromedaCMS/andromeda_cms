# frozen_string_literal: true

# The dummy app runs inside the gem's own bundle rather than one of its own,
# so there is no Gemfile to point BUNDLE_GEMFILE at.
require "bundler/setup"
