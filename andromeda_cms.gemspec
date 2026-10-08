# frozen_string_literal: true

require_relative "lib/andromeda/version"

Gem::Specification.new do |spec|
  spec.name = "andromeda_cms"
  spec.version = Andromeda::VERSION
  spec.authors = ["LIMHAUS Inc."]
  spec.email = ["hi@andromedacms.dev"]

  spec.summary = "Astro-compatible content collections for Ruby on Rails"
  spec.description = <<~TEXT
    Andromeda brings Astro's content collections to an ordinary Ruby on Rails
    app. Markdown and MDX files copied from an Astro project are validated
    against a schema and converted at deploy time, while pages stay ordinary
    Rails controllers and views.
  TEXT
  spec.homepage = "https://www.andromedacms.dev"
  spec.license = "MIT"

  source_code_uri = "https://github.com/AndromedaCMS/andromeda_cms"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = source_code_uri
  spec.metadata["documentation_uri"] = "#{spec.homepage}/docs"
  spec.metadata["changelog_uri"] = "#{source_code_uri}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{source_code_uri}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Magnus supports 3.2 and newer, and Rails 8 requires 3.2 as well.
  spec.required_ruby_version = ">= 3.2.0"

  # Rake tasks, generator USAGE text and generator templates are as much a
  # part of the gem as its Ruby files, so the list is by directory rather
  # than by extension.
  spec.files = Dir[
    "lib/**/*",
    "ext/**/*.{rs,rb,toml,lock}",
    "Cargo.toml",
    "Cargo.lock",
    "LICENSE.txt",
    "README.md",
    "CHANGELOG.md",
    "CONTRIBUTING.md"
  ].reject do |path|
    # `rake compile` drops the built extension into lib/; packaging it would
    # ship one machine's binary inside the source gem.
    File.directory?(path) || path.match?(/\.(bundle|so|dll|dylib)\z/)
  end
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/andromeda_cms/extconf.rb"]

  # Rails 8 is the first version where Propshaft is the default asset pipeline,
  # which is what the image handling assumes.
  spec.add_dependency "railties", ">= 8.0"
  spec.add_dependency "activesupport", ">= 8.0"
  # Stands in for Shiki: same markup shape, approximate colours.
  spec.add_dependency "rouge", ">= 4.0"
  # Pure-Ruby TOML parser (no native extension to cross-compile) for `+++`
  # frontmatter blocks; see lib/andromeda/frontmatter.rb for why this gem was
  # chosen over toml-rb/tomlib.
  spec.add_dependency "tomlrb", ">= 2.0"
  # Rails 8.1 calls JSON.parse with a positional options hash, which json 3
  # removed, so decrypting a session cookie raises ArgumentError. Drop this
  # bound once Rails ships a fix.
  spec.add_dependency "json", "< 3"
end
