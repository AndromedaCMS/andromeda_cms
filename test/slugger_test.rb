# frozen_string_literal: true

require "test_helper"

class SluggerTest < Minitest::Test
  def test_basic_ascii
    assert_equal "hello-world", Andromeda::Slugger.new.slug("Hello World")
  end

  def test_downcases
    assert_equal "foocamelcase", Andromeda::Slugger.new.slug("fooCamelCase")
  end

  def test_strips_punctuation
    assert_equal "this-is-markdown", Andromeda::Slugger.new.slug("This is [Markdown]!")
  end

  def test_collapses_non_space_punctuation_without_adding_hyphens
    # github-slugger strips punctuation first, then turns *spaces* (not the
    # gaps left behind) into hyphens -- so "don't" loses the apostrophe
    # without gaining a hyphen in its place.
    assert_equal "dont-stop", Andromeda::Slugger.new.slug("don't stop")
  end

  def test_japanese_headings_stay_readable
    assert_equal "はじめに", Andromeda::Slugger.new.slug("はじめに")
  end

  def test_japanese_with_ascii_punctuation
    assert_equal "第1章-導入", Andromeda::Slugger.new.slug("第1章: 導入")
  end

  def test_emoji_is_stripped_like_upstream
    # Counterintuitive but verified against github-slugger's own
    # test/fixtures.json ("😄 unicode emoji" => "-unicode-emoji"): emoji
    # fall in Unicode categories the strip regex excludes, same as other
    # symbols/punctuation. Only *letters* (e.g. Japanese kana/kanji) are
    # guaranteed to survive -- "non-ASCII" support means "not stripped
    # just for being non-ASCII", not "every non-ASCII character is kept".
    assert_equal "party--time", Andromeda::Slugger.new.slug("party 🎉 time")
  end

  def test_duplicate_headings_get_numbered_suffixes
    slugger = Andromeda::Slugger.new

    assert_equal "intro", slugger.slug("Intro")
    assert_equal "intro-1", slugger.slug("Intro")
    assert_equal "intro-2", slugger.slug("Intro")
  end

  def test_duplicate_detection_is_per_instance
    assert_equal "intro", Andromeda::Slugger.new.slug("Intro")
    assert_equal "intro", Andromeda::Slugger.new.slug("Intro")
  end

  def test_reset_forgets_previous_slugs
    slugger = Andromeda::Slugger.new
    slugger.slug("Intro")

    slugger.reset

    assert_equal "intro", slugger.slug("Intro")
  end

  def test_a_literal_occurrence_can_collide_with_a_generated_suffix
    # Matches github-slugger's own fixture: an explicit "foxtrot-1" heading
    # occupies that slug, so a *third* "foxtrot" has to skip past it to
    # "foxtrot-2" (the collision loop is a `while`, not a one-shot bump).
    slugger = Andromeda::Slugger.new

    assert_equal "foxtrot-1", slugger.slug("foxtrot-1")
    assert_equal "foxtrot", slugger.slug("foxtrot")
    assert_equal "foxtrot-2", slugger.slug("foxtrot")
  end

  def test_leading_and_trailing_spaces
    assert_equal "-hello-", Andromeda::Slugger.new.slug(" hello ")
  end

  def test_empty_heading_text
    assert_equal "", Andromeda::Slugger.new.slug("")
  end

  def test_heading_text_that_is_entirely_punctuation_slugs_to_empty
    assert_equal "", Andromeda::Slugger.new.slug("...")
  end

  def test_non_string_input_returns_empty_string
    assert_equal "", Andromeda::Slugger.slugify(nil)
  end

  def test_stateless_slugify_never_appends_a_suffix
    assert_equal "asd", Andromeda::Slugger.slugify("asd")
    assert_equal "asd", Andromeda::Slugger.slugify("asd")
  end

  def test_prototype_pollution_keys_are_handled_like_any_other_string
    slugger = Andromeda::Slugger.new

    assert_equal "__proto__", slugger.slug("__proto__")
    assert_equal "__proto__-1", slugger.slug("__proto__")
    assert_equal "hasownproperty", slugger.slug("hasOwnProperty")
  end
end
