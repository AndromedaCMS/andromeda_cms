# frozen_string_literal: true

require "test_helper"

class RelationTest < Minitest::Test
  Record = Struct.new(:id, :data)

  def relation(*rows)
    Andromeda::Relation.new(rows.map { |id, data| Record.new(id, data) })
  end

  def ids(relation)
    relation.to_a.map(&:id)
  end

  # --- where ---------------------------------------------------------------------

  def test_where_with_several_keys_requires_all_of_them
    posts = relation(["a", { draft: false, lang: "en" }], ["b", { draft: false, lang: "ja" }],
                     ["c", { draft: true, lang: "en" }])

    assert_equal ["a"], ids(posts.where(draft: false, lang: "en"))
  end

  # Equality, not membership: documented so nobody expects `where(tags: "x")`
  # to search inside an array.
  def test_where_compares_array_values_by_equality
    posts = relation(["a", { tags: %w[rails astro] }], ["b", { tags: %w[rails] }])

    assert_equal ["b"], ids(posts.where(tags: %w[rails]))
    assert_equal ["a"], ids(posts.where { |post| post.data[:tags].include?("astro") })
  end

  # --- order ---------------------------------------------------------------------

  def test_order_applies_later_keys_only_to_ties_in_earlier_ones
    posts = relation(["a", { year: 2025, title: "b" }], ["b", { year: 2026, title: "z" }],
                     ["c", { year: 2025, title: "a" }])

    assert_equal %w[b c a], ids(posts.order({ year: :desc }, :title))
  end

  # JavaScript's sort is stable, so an Astro listing keeps same-day posts in
  # their original order. Many ties make an unstable sort visibly reorder.
  def test_order_is_stable_for_ties
    rows = (1..40).map { |i| [format("p%02d", i), { group: i % 2 }] }
    sorted = ids(relation(*rows).order(:group))

    assert_equal rows.select { |_, d| d[:group].zero? }.map(&:first) + rows.reject { |_, d| d[:group].zero? }.map(&:first),
                 sorted
  end

  def test_order_treats_nil_as_a_tie_and_keeps_original_order
    posts = relation(["a", { rank: nil }], ["b", { rank: 1 }], ["c", { rank: nil }])

    assert_equal %w[a b c], ids(posts.order(:rank))
  end
end
