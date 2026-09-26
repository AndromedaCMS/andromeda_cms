# frozen_string_literal: true

require_relative "andromeda/version"
require_relative "andromeda/errors"
require_relative "andromeda/configuration"
require_relative "andromeda/assets"
require_relative "andromeda/helpers"
require_relative "andromeda/fix"
require_relative "andromeda/check"
require_relative "andromeda/frontmatter"
require_relative "andromeda/schema"
require_relative "andromeda/slugger"
require_relative "andromeda/renderer"
require_relative "andromeda/components"
require_relative "andromeda/id"
require_relative "andromeda/relation"
require_relative "andromeda/registry"
require_relative "andromeda/loader"
require_relative "andromeda/entry"
require_relative "andromeda/store"
require_relative "andromeda/pipeline"

module Andromeda
  # The native extension is built per Ruby minor version, so prefer the
  # version-specific build when the packaged gem ships several of them.
  begin
    RUBY_VERSION =~ /(\d+\.\d+)/
    require_relative "andromeda_cms/#{Regexp.last_match(1)}/andromeda_cms"
  rescue LoadError
    require_relative "andromeda_cms/andromeda_cms"
  end

  # Ruby wrapper around the native module the require above just defined;
  # must load after it since it reopens Andromeda::Parser.
  require_relative "andromeda/parser"
end

# Loaded last so the Railtie can reference everything above it. The guard is
# on `Rails` itself, not `Rails::Railtie`: an application requires this gem
# before Rails has finished pulling in the railtie machinery.
require_relative "andromeda/railtie" if defined?(::Rails)
