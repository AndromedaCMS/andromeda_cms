# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "securerandom"

class RegistryTest < Minitest::Test
  # Andromeda::Registry is process-global state shared with every other test
  # file in the suite (rake test runs everything in one process). Anything
  # that calls `clear!`/`discover` here must restore exactly what it found,
  # or an unrelated test elsewhere (e.g. entry_test's lazy `reference`
  # resolution, which looks classes up by name through this same registry)
  # could break depending on Minitest's random run order.
  def setup
    @saved = Andromeda::Registry.collection_names.each_with_object({}) { |name, h| h[name] = Andromeda::Registry[name] }
  end

  def teardown
    Andromeda::Registry.clear!
    @saved.each { |name, klass| Andromeda::Registry.register(name, klass) }
  end

  def unique_name
    :"registry_test_#{SecureRandom.hex(4)}"
  end

  # --- register / lookup -----------------------------------------------------

  def test_two_collections_coexist_independently
    name_a = unique_name
    name_b = unique_name
    class_a = Class.new(Andromeda::Entry)
    class_b = Class.new(Andromeda::Entry)

    Andromeda::Registry.register(name_a, class_a)
    Andromeda::Registry.register(name_b, class_b)

    assert_same class_a, Andromeda::Registry[name_a]
    assert_same class_b, Andromeda::Registry[name_b]
    refute_same Andromeda::Registry[name_a], Andromeda::Registry[name_b]
  end

  def test_lookup_accepts_string_or_symbol
    name = unique_name
    klass = Class.new(Andromeda::Entry)
    Andromeda::Registry.register(name, klass)

    assert_same klass, Andromeda::Registry[name.to_s]
  end

  def test_unknown_collection_returns_nil
    assert_nil Andromeda::Registry[unique_name]
  end

  def test_get_collection_raises_unknown_collection_for_an_unregistered_name
    assert_raises(Andromeda::UnknownCollection) { Andromeda.get_collection(unique_name) }
  end

  def test_get_entry_raises_unknown_collection_for_an_unregistered_name
    assert_raises(Andromeda::UnknownCollection) { Andromeda.get_entry(unique_name, "whatever") }
  end

  # --- module-level Andromeda.get_collection / get_entry ----------------------

  def test_module_helpers_delegate_to_the_registered_class
    name = unique_name
    klass = Class.new(Andromeda::Entry) do
      collection name, base: File.expand_path("fixtures/loader/blog", __dir__)
      attribute :title, :string, required: true
      attribute :pub_date, :date, required: true
    end

    assert_equal 3, Andromeda.get_collection(name).count
    assert_equal "Hello World", Andromeda.get_entry(name, "hello-world").title
  end

  # --- discovery from a directory ---------------------------------------------

  def test_discover_loads_entry_classes_from_a_directory_and_registers_them
    Dir.mktmpdir do |dir|
      const_a = "RegistryDiscoveryA#{SecureRandom.hex(4)}"
      const_b = "RegistryDiscoveryB#{SecureRandom.hex(4)}"
      name_a = unique_name
      name_b = unique_name

      write_entry_class(dir, "a.rb", const_a, name_a)
      write_entry_class(dir, "b.rb", const_b, name_b)

      Andromeda::Registry.discover(dir)

      assert_kind_of Class, Andromeda::Registry[name_a]
      assert_kind_of Class, Andromeda::Registry[name_b]
      assert_equal name_a, Andromeda::Registry[name_a].collection_name
    end
  end

  def test_discover_clears_stale_registrations_from_a_previous_run
    Dir.mktmpdir do |dir|
      const_a = "RegistryDiscoveryStaleA#{SecureRandom.hex(4)}"
      const_b = "RegistryDiscoveryStaleB#{SecureRandom.hex(4)}"
      name_a = unique_name
      name_b = unique_name

      write_entry_class(dir, "a.rb", const_a, name_a)
      write_entry_class(dir, "b.rb", const_b, name_b)
      Andromeda::Registry.discover(dir)
      assert Andromeda::Registry[name_a]
      assert Andromeda::Registry[name_b]

      # Simulate a file having been deleted/renamed between two boots --
      # the collection it used to register must not linger afterward.
      File.delete(File.join(dir, "b.rb"))
      Andromeda::Registry.discover(dir)

      assert Andromeda::Registry[name_a], "surviving file's registration should remain"
      assert_nil Andromeda::Registry[name_b], "removed file's registration must not linger as a stale entry"
    end
  end

  def test_discover_run_twice_does_not_duplicate_registrations
    Dir.mktmpdir do |dir|
      const_a = "RegistryDiscoveryTwiceA#{SecureRandom.hex(4)}"
      name_a = unique_name
      write_entry_class(dir, "a.rb", const_a, name_a)

      Andromeda::Registry.discover(dir)
      first_count = Andromeda::Registry.collection_names.size
      Andromeda::Registry.discover(dir)
      second_count = Andromeda::Registry.collection_names.size

      assert_equal first_count, second_count
    end
  end

  def test_discover_defaults_to_an_empty_directory_being_a_no_op
    Dir.mktmpdir do |dir|
      Andromeda::Registry.discover(dir)

      assert_empty Andromeda::Registry.collection_names
    end
  end

  private

  # Writes a minimal Entry subclass to `dir/filename`, using a fresh
  # top-level constant name each time (Ruby class reopening would otherwise
  # make repeated runs across the whole test suite interfere with each
  # other through a shared constant).
  def write_entry_class(dir, filename, const_name, collection_name)
    File.write(File.join(dir, filename), <<~RUBY)
      class #{const_name} < Andromeda::Entry
        collection :#{collection_name}, base: "\#{__dir__}"
      end
    RUBY
  end
end
