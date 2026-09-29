# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class SchemaTest < Minitest::Test
  # --- building --------------------------------------------------------

  def test_attribute_returns_self_so_calls_can_chain
    schema = Andromeda::Schema.new
    result = schema.attribute(:title, :string)

    assert_same schema, result
  end

  def test_unknown_type_raises_at_definition_time
    error = assert_raises(ArgumentError) do
      Andromeda::Schema.new { |s| s.attribute :title, :bogus }
    end

    assert_match(/unknown attribute type/, error.message)
  end

  def test_enum_without_values_raises_at_definition_time
    assert_raises(ArgumentError) { Andromeda::Schema.new { |s| s.attribute :status, :enum } }
  end

  def test_reference_without_collection_raises_at_definition_time
    assert_raises(ArgumentError) { Andromeda::Schema.new { |s| s.attribute :author, :reference } }
  end

  def test_array_of_reference_without_collection_raises_at_definition_time
    assert_raises(ArgumentError) { Andromeda::Schema.new { |s| s.attribute :tags, :array, of: :reference } }
  end

  def test_array_of_enum_without_values_raises_at_definition_time
    assert_raises(ArgumentError) { Andromeda::Schema.new { |s| s.attribute :statuses, :array, of: :enum } }
  end

  # --- string ------------------------------------------------------------

  def test_string_valid
    schema = string_schema
    result = schema.validate({ "title" => "Hello" })

    assert_predicate result, :valid?
    assert_equal "Hello", result.data[:title]
  end

  def test_string_rejects_non_string_without_coercion
    schema = string_schema
    result = schema.validate({ "title" => 42 })

    refute_predicate result, :valid?
    assert_equal "title: 42 is not a string", result.problems.first.message
  end

  # --- required / missing / false / nil -----------------------------------

  def test_required_missing_key_is_a_problem
    schema = Andromeda::Schema.new { |s| s.attribute :title, :string, required: true }
    result = schema.validate({})

    refute_predicate result, :valid?
    assert_equal "title is required", result.problems.first.message
  end

  def test_required_false_boolean_is_present_not_missing
    schema = Andromeda::Schema.new { |s| s.attribute :draft, :boolean, required: true }
    result = schema.validate({ "draft" => false })

    assert_predicate result, :valid?
    assert_equal false, result.data[:draft]
  end

  def test_required_explicit_nil_is_still_a_problem
    schema = Andromeda::Schema.new { |s| s.attribute :title, :string, required: true }
    result = schema.validate({ "title" => nil })

    refute_predicate result, :valid?
    assert_equal "title is required", result.problems.first.message
  end

  def test_optional_explicit_nil_is_kept_as_nil_not_replaced_by_default
    schema = Andromeda::Schema.new { |s| s.attribute :subtitle, :string, default: "n/a" }
    result = schema.validate({ "subtitle" => nil })

    assert_predicate result, :valid?
    assert_nil result.data[:subtitle]
  end

  # --- default -------------------------------------------------------------

  def test_default_value_applied_when_key_absent
    schema = Andromeda::Schema.new { |s| s.attribute :draft, :boolean, default: false }
    result = schema.validate({})

    assert_predicate result, :valid?
    assert_equal false, result.data[:draft]
  end

  def test_default_callable_invoked_per_validation
    calls = 0
    schema = Andromeda::Schema.new { |s| s.attribute :seq, :integer, default: -> { calls += 1 } }

    schema.validate({})
    schema.validate({})

    assert_equal 2, calls
  end

  def test_default_array_is_not_shared_between_validations
    schema = Andromeda::Schema.new { |s| s.attribute :tags, :array, of: :string, default: [] }

    first = schema.validate({}).data[:tags]
    first << "leaked"
    second = schema.validate({}).data[:tags]

    assert_empty second
  end

  # --- integer / float -----------------------------------------------------

  def test_integer_valid
    schema = Andromeda::Schema.new { |s| s.attribute :count, :integer }

    assert_equal 5, schema.validate({ "count" => 5 }).data[:count]
  end

  def test_integer_rejects_float
    schema = Andromeda::Schema.new { |s| s.attribute :count, :integer }
    result = schema.validate({ "count" => 5.5 })

    refute_predicate result, :valid?
    assert_equal "count: 5.5 is not an integer", result.problems.first.message
  end

  def test_float_accepts_integer_and_coerces
    schema = Andromeda::Schema.new { |s| s.attribute :ratio, :float }

    assert_equal 5.0, schema.validate({ "ratio" => 5 }).data[:ratio]
  end

  def test_float_rejects_string
    schema = Andromeda::Schema.new { |s| s.attribute :ratio, :float }

    refute_predicate schema.validate({ "ratio" => "5.5" }), :valid?
  end

  # --- boolean ---------------------------------------------------------------

  def test_boolean_rejects_truthy_string
    schema = Andromeda::Schema.new { |s| s.attribute :draft, :boolean }
    result = schema.validate({ "draft" => "true" })

    refute_predicate result, :valid?
    assert_equal 'draft: "true" is not a boolean', result.problems.first.message
  end

  # --- date / datetime -------------------------------------------------------

  def test_date_accepts_real_date_untouched
    date = Date.new(2022, 7, 8)
    schema = date_schema

    assert_equal date, schema.validate({ "pub_date" => date }).data[:pub_date]
  end

  def test_date_coerces_astro_style_string
    schema = date_schema
    result = schema.validate({ "pub_date" => "Jul 08 2022" })

    assert_predicate result, :valid?
    assert_equal Date.new(2022, 7, 8), result.data[:pub_date]
  end

  def test_date_coerces_iso_string
    schema = date_schema
    result = schema.validate({ "pub_date" => "2026-09-22" })

    assert_predicate result, :valid?
    assert_equal Date.new(2026, 9, 22), result.data[:pub_date]
  end

  def test_date_rejects_invalid_string
    schema = date_schema
    result = schema.validate({ "pub_date" => "not a date" })

    refute_predicate result, :valid?
    assert_equal 'pub_date: "not a date" is not a valid date', result.problems.first.message
  end

  def test_date_accepts_time_by_truncating
    schema = date_schema
    time = Time.new(2022, 7, 8, 10, 30)

    assert_equal Date.new(2022, 7, 8), schema.validate({ "pub_date" => time }).data[:pub_date]
  end

  def test_datetime_coerces_iso_string
    schema = Andromeda::Schema.new { |s| s.attribute :updated_at, :datetime }
    result = schema.validate({ "updated_at" => "2026-09-22T10:00:00Z" })

    assert_predicate result, :valid?
    assert_kind_of Time, result.data[:updated_at]
  end

  def test_datetime_accepts_date_by_expanding
    schema = Andromeda::Schema.new { |s| s.attribute :updated_at, :datetime }
    result = schema.validate({ "updated_at" => Date.new(2022, 7, 8) })

    assert_predicate result, :valid?
    assert_kind_of Time, result.data[:updated_at]
  end

  def test_datetime_rejects_invalid_string
    schema = Andromeda::Schema.new { |s| s.attribute :updated_at, :datetime }
    result = schema.validate({ "updated_at" => "not a datetime" })

    refute_predicate result, :valid?
    assert_equal 'updated_at: "not a datetime" is not a valid datetime', result.problems.first.message
  end

  # --- array -------------------------------------------------------------

  def test_array_of_string_valid
    schema = Andromeda::Schema.new { |s| s.attribute :tags, :array, of: :string }

    assert_equal %w[rails astro], schema.validate({ "tags" => %w[rails astro] }).data[:tags]
  end

  def test_array_empty_is_valid
    schema = Andromeda::Schema.new { |s| s.attribute :tags, :array, of: :string }

    assert_empty schema.validate({ "tags" => [] }).data[:tags]
  end

  def test_array_rejects_non_array
    schema = Andromeda::Schema.new { |s| s.attribute :tags, :array, of: :string }

    refute_predicate schema.validate({ "tags" => "rails" }), :valid?
  end

  def test_array_reports_wrong_element_type
    schema = Andromeda::Schema.new { |s| s.attribute :tags, :array, of: :string }
    result = schema.validate({ "tags" => ["rails", 42] })

    refute_predicate result, :valid?
    assert_includes result.problems.first.message, "[1]"
  end

  def test_array_of_reference_carries_the_collection_to_each_element
    schema = Andromeda::Schema.new { |s| s.attribute :tags, :array, of: :reference, collection: :tags }
    result = schema.validate({ "tags" => ["exam-prep", { "id" => "abroad" }] })

    assert_predicate result, :valid?
    assert_equal [:tags, :tags], result.data[:tags].map(&:collection)
    assert_equal %w[exam-prep abroad], result.data[:tags].map(&:id)
  end

  def test_array_of_reference_rejects_an_element_from_another_collection
    schema = Andromeda::Schema.new { |s| s.attribute :tags, :array, of: :reference, collection: :tags }
    result = schema.validate({ "tags" => [{ "id" => "jane", "collection" => "authors" }] })

    refute_predicate result, :valid?
    assert_match(/does not match declared collection/, result.problems.first.message)
  end

  def test_array_of_enum_checks_each_element_against_values
    schema = Andromeda::Schema.new { |s| s.attribute :statuses, :array, of: :enum, values: %w[draft published] }

    assert_equal %w[draft published], schema.validate({ "statuses" => %w[draft published] }).data[:statuses]
    refute_predicate schema.validate({ "statuses" => %w[draft archived] }), :valid?
  end

  def test_array_without_of_passes_elements_through
    schema = Andromeda::Schema.new { |s| s.attribute :anything, :array }

    assert_equal [1, "two", true], schema.validate({ "anything" => [1, "two", true] }).data[:anything]
  end

  # --- hash ----------------------------------------------------------------

  def test_hash_valid
    schema = Andromeda::Schema.new { |s| s.attribute :meta, :hash }

    assert_equal({ "a" => 1 }, schema.validate({ "meta" => { "a" => 1 } }).data[:meta])
  end

  def test_hash_rejects_non_hash
    schema = Andromeda::Schema.new { |s| s.attribute :meta, :hash }

    refute_predicate schema.validate({ "meta" => "nope" }), :valid?
  end

  # --- enum ------------------------------------------------------------------

  def test_enum_valid
    schema = Andromeda::Schema.new { |s| s.attribute :status, :enum, values: %w[draft published] }

    assert_equal "draft", schema.validate({ "status" => "draft" }).data[:status]
  end

  def test_enum_invalid_lists_allowed_values
    schema = Andromeda::Schema.new { |s| s.attribute :status, :enum, values: %w[draft published] }
    result = schema.validate({ "status" => "archived" })

    refute_predicate result, :valid?
    assert_equal 'status: "archived" is not one of draft, published', result.problems.first.message
  end

  # --- image -----------------------------------------------------------------

  def test_image_valid_when_file_exists
    with_content_root do |root, entry_path|
      FileUtils.touch(File.join(root, "cover.png"))
      schema = image_schema
      result = schema.validate({ "cover" => "./cover.png" }, entry_path: entry_path, content_root: root)

      assert_predicate result, :valid?
      image = result.data[:cover]
      assert_kind_of Andromeda::Image, image
      assert_equal "cover.png", image.relative_path
      assert_equal File.join(root, "cover.png"), image.path
    end
  end

  def test_image_missing_file_is_a_problem
    with_content_root do |root, entry_path|
      schema = image_schema
      result = schema.validate({ "cover" => "./missing.png" }, entry_path: entry_path, content_root: root)

      refute_predicate result, :valid?
      assert_match(/does not exist/, result.problems.first.message)
    end
  end

  def test_image_path_escaping_content_root_is_rejected
    with_content_root do |root, entry_path|
      # A sibling file outside the collection's base -- reachable on disk,
      # but must never be reachable through a content-relative path.
      FileUtils.touch(File.join(File.dirname(root), "secret.png"))
      schema = image_schema
      result = schema.validate({ "cover" => "../secret.png" }, entry_path: entry_path, content_root: root)

      refute_predicate result, :valid?
      assert_match(/outside the project/, result.problems.first.message)
    end
  end

  def test_image_without_context_is_a_problem_not_an_exception
    schema = image_schema
    result = schema.validate({ "cover" => "./cover.png" })

    refute_predicate result, :valid?
    assert_match(/entry_path/, result.problems.first.message)
  end

  # --- reference ---------------------------------------------------------------

  def test_reference_string_form
    schema = reference_schema
    result = schema.validate({ "author" => "jane" })

    assert_predicate result, :valid?
    ref = result.data[:author]
    assert_equal :authors, ref.collection
    assert_equal "jane", ref.id
  end

  def test_reference_hash_form
    schema = reference_schema
    result = schema.validate({ "author" => { "id" => "jane", "collection" => "authors" } })

    assert_predicate result, :valid?
    ref = result.data[:author]
    assert_equal :authors, ref.collection
    assert_equal "jane", ref.id
  end

  def test_reference_hash_form_with_wrong_collection_is_a_problem
    schema = reference_schema
    result = schema.validate({ "author" => { "id" => "jane", "collection" => "people" } })

    refute_predicate result, :valid?
    assert_match(/does not match declared collection/, result.problems.first.message)
  end

  def test_reference_hash_form_missing_id_is_a_problem
    schema = reference_schema
    result = schema.validate({ "author" => { "collection" => "authors" } })

    refute_predicate result, :valid?
  end

  # --- multiple problems, order, and unknown/non-snake-case keys ---------------

  def test_multiple_problems_reported_together_in_declaration_order
    schema = Andromeda::Schema.new do |s|
      s.attribute :title, :string, required: true
      s.attribute :count, :integer
    end
    result = schema.validate({ "count" => "not a number" })

    refute_predicate result, :valid?
    assert_equal 2, result.problems.size
    assert_equal "title is required", result.problems[0].message
    assert_equal "count: \"not a number\" is not an integer", result.problems[1].message
  end

  def test_problem_order_is_stable_across_repeated_calls
    schema = Andromeda::Schema.new do |s|
      s.attribute :title, :string, required: true
      s.attribute :count, :integer, required: true
    end
    data = {}

    first = schema.validate(data).problems.map(&:message)
    second = schema.validate(data).problems.map(&:message)

    assert_equal first, second
  end

  def test_non_snake_case_key_names_the_fix
    schema = date_schema
    result = schema.validate({ "pub_date" => "2026-01-01", "pubDate" => "2026-01-01" })

    refute_predicate result, :valid?
    problem = result.problems.find { |p| p.message.include?("pubDate") }
    assert_match(/andromeda:fix/, problem.message)
    assert_match(/pub_date/, problem.message)
  end

  def test_unknown_keys_are_preserved_and_exposed_separately
    schema = string_schema
    result = schema.validate({ "title" => "Hello", "extra" => "kept" })

    assert_predicate result, :valid?
    assert_equal "kept", result.data["extra"]
    assert_equal({ "extra" => "kept" }, result.unknown_keys)
  end

  def test_unknown_keys_exposed_even_when_invalid
    schema = Andromeda::Schema.new { |s| s.attribute :title, :string, required: true }
    result = schema.validate({ "extra" => "kept" })

    refute_predicate result, :valid?
    assert_equal({ "extra" => "kept" }, result.unknown_keys)
  end

  # --- validate! / ValidationError ----------------------------------------------

  def test_validate_bang_returns_data_on_success
    schema = string_schema

    assert_equal({ title: "Hello" }, schema.validate!({ "title" => "Hello" }))
  end

  def test_validate_bang_raises_validation_error_without_path
    schema = date_schema
    error = assert_raises(Andromeda::ValidationError) { schema.validate!({ "pub_date" => "not a date" }) }

    assert_equal 'pub_date: "not a date" is not a valid date', error.message
  end

  def test_validate_bang_raises_validation_error_with_path
    schema = Andromeda::Schema.new { |s| s.attribute :title, :string, required: true }
    error = assert_raises(Andromeda::ValidationError) do
      schema.validate!({}, path: "app/content/blog/x.md")
    end

    assert_equal "app/content/blog/x.md: title is required", error.message
  end

  def test_validate_bang_error_lists_every_problem_on_its_own_line
    schema = Andromeda::Schema.new do |s|
      s.attribute :title, :string, required: true
      s.attribute :count, :integer, required: true
    end
    error = assert_raises(Andromeda::ValidationError) { schema.validate!({}, path: "x.md") }

    assert_equal "x.md: title is required\nx.md: count is required", error.message
    assert_equal 2, error.problems.size
  end

  # JavaScript has one number type, so Zod's `.int()` accepts `3.0`.
  def test_integer_accepts_a_whole_float_like_zod
    schema = Andromeda::Schema.new { |s| s.attribute :count, :integer }
    result = schema.validate({ "count" => 3.0 })

    assert_predicate result, :valid?
    assert_equal 3, result.data[:count]
    assert_kind_of Integer, result.data[:count]
  end

  def test_integer_still_rejects_non_finite_floats
    schema = Andromeda::Schema.new { |s| s.attribute :count, :integer }

    refute_predicate schema.validate({ "count" => Float::INFINITY }), :valid?
    refute_predicate schema.validate({ "count" => Float::NAN }), :valid?
  end

  private

  def string_schema
    Andromeda::Schema.new { |s| s.attribute :title, :string, required: true }
  end

  def date_schema
    Andromeda::Schema.new { |s| s.attribute :pub_date, :date, required: true }
  end

  def image_schema
    Andromeda::Schema.new { |s| s.attribute :cover, :image }
  end

  def reference_schema
    Andromeda::Schema.new { |s| s.attribute :author, :reference, collection: :authors }
  end

  # Yields `[content_root, entry_path]` for an entry file sitting directly
  # inside a throwaway content root, mirroring app/content/<collection>/.
  def with_content_root
    Dir.mktmpdir do |dir|
      root = File.join(dir, "blog")
      FileUtils.mkdir_p(root)
      entry_path = File.join(root, "hello.md")
      FileUtils.touch(entry_path)
      yield root, entry_path
    end
  end
end
