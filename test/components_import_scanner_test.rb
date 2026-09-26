# frozen_string_literal: true

require "test_helper"

class ComponentsImportScannerTest < Minitest::Test
  def scan(source)
    tree = Andromeda::Parser.parse(source, mdx: true)
    Andromeda::Components::ImportScanner.scan(tree)
  end

  def test_default_import
    imports = scan("import Callout from 'content_components/callout'\n\nbody")
    assert_equal({ "Callout" => "content_components/callout" }, imports)
  end

  def test_named_imports
    imports = scan("import { Tabs, TabItem } from '@astrojs/starlight/components'\n\nbody")
    assert_equal(
      { "Tabs" => "@astrojs/starlight/components", "TabItem" => "@astrojs/starlight/components" },
      imports
    )
  end

  def test_named_import_with_as_rename
    imports = scan("import { TabItem as Item } from 'content_components/tab_item'\n\nbody")
    assert_equal({ "Item" => "content_components/tab_item" }, imports)
  end

  def test_ignores_image_imports_gracefully_when_unused
    imports = scan("import cover from './cover.png'\n\nbody")
    assert_equal({ "cover" => "./cover.png" }, imports)
  end

  def test_multiple_import_statements
    imports = scan(<<~MDX)
      import Callout from 'content_components/callout'
      import { Tabs, TabItem as Item } from 'content_components/tabs'

      body
    MDX

    assert_equal(
      {
        "Callout" => "content_components/callout",
        "Tabs" => "content_components/tabs",
        "Item" => "content_components/tabs"
      },
      imports
    )
  end

  def test_no_imports_returns_empty_hash
    assert_equal({}, scan("just a paragraph"))
  end
end
