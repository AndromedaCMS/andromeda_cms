# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    Andromeda.reset_config!
  end

  def teardown
    Andromeda.reset_config!
  end

  def test_defaults_match_the_documented_layout
    config = Andromeda.config

    assert_equal "app/content", config.content_path
    assert_equal "Content", config.entry_namespace
    assert_equal "app/views/content_components", config.components_path
    assert_equal ".andromeda", config.build_path
    assert_equal :development, config.mode
  end

  def test_configure_yields_and_returns_the_configuration
    returned = Andromeda.configure { |config| config.content_path = "content" }

    assert_equal "content", Andromeda.config.content_path
    assert_same Andromeda.config, returned
  end

  def test_entry_class_path_follows_the_namespace
    Andromeda.configure { |config| config.entry_namespace = "Contents" }

    assert_equal "app/models/contents", Andromeda.config.entry_class_path
  end

  def test_entry_class_path_handles_a_nested_namespace
    Andromeda.configure { |config| config.entry_namespace = "Cms::Content" }

    assert_equal "app/models/cms/content", Andromeda.config.entry_class_path
  end

  def test_reset_restores_defaults
    Andromeda.configure { |config| config.build_path = "tmp/andromeda" }
    Andromeda.reset_config!

    assert_equal ".andromeda", Andromeda.config.build_path
  end

  def test_mode_can_be_switched_to_production
    Andromeda.configure { |config| config.mode = :production }

    assert_equal :production, Andromeda.config.mode
  end

  # A lookup made before Rails has a root must not pin the working directory
  # for the rest of the process.
  def test_project_root_is_resolved_on_every_call_not_memoized
    config = Andromeda::Configuration.new
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        config.stub(:rails_root, nil) { assert_equal File.realpath(dir), File.realpath(config.project_root) }
      end
      config.stub(:rails_root, "/srv/app") { assert_equal "/srv/app", config.project_root }
    end
  end

  def test_an_explicit_project_root_wins_over_rails
    config = Andromeda::Configuration.new
    config.project_root = "/elsewhere"

    config.stub(:rails_root, "/srv/app") { assert_equal "/elsewhere", config.project_root }
  end
end
