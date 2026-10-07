# frozen_string_literal: true

module Andromeda
  # View helpers mixed into ActionView by the Railtie. Everything here is a
  # thin presentation layer over data the build already produced: no parsing
  # or rendering happens while serving a request.
  module Helpers
    # Outputs an entry's converted body, wrapped in `<andromeda-content>` so
    # it can be targeted from CSS. Inside a component rendered at conversion
    # time the wrapper is left out: the component's output is stored in the
    # entry's html and wrapped once, when the page is served. Marked
    # html_safe because the build
    # produced this markup from content the application's own authors wrote,
    # the same trust model Astro applies to `.md`/`.mdx` (see 13_security).
    # Inside a component rendered at conversion time the asset markers are
    # left in place, for the same reason `andromeda_image_url` leaves them.
    #
    # @param entry [Andromeda::Entry]
    # @return [ActiveSupport::SafeBuffer]
    def andromeda_content(entry)
      return entry.html.html_safe if Andromeda::BuildContext.converting? # rubocop:disable Rails/OutputSafety

      tag.send("andromeda-content", Andromeda::Assets.resolve(entry.html).html_safe) # rubocop:disable Rails/OutputSafety
    end

    # Inside a component partial rendered at conversion time, this returns
    # the asset marker instead of a URL: the digest does not exist until
    # `assets:precompile` runs, after the build, and `andromeda_content`
    # resolves the marker when the page is served.
    #
    # @param image [Andromeda::Image, nil] an `image` attribute's value.
    # @return [String, nil] its URL, or nil when the attribute is unset.
    def andromeda_image_url(image)
      return nil if image.nil?

      source = image.asset || image.relative_path
      Andromeda::BuildContext.converting? ? source : Andromeda::Assets.resolve(source)
    end

    # Lets `image_tag andromeda_image_url(src)` work at conversion time.
    # The marker has no `//`, so Rails would take it for a logical path and
    # Propshaft would fail to find it; passing it through leaves it for
    # `andromeda_content` to resolve like any other marker. Every asset
    # helper (`image_tag`, `image_path`, `asset_url`...) goes through here.
    def asset_path(source, options = {})
      return source if Andromeda::BuildContext.converting? && source.to_s.start_with?(Andromeda::Assets::MARKER)

      super
    end

    # `image_tag` and `asset_url` call this alias, which Rails binds to its
    # own `asset_path` and so would skip the override above.
    def path_to_asset(source, options = {})
      asset_path(source, options)
    end

    # Renders a nested table of contents from `entry.headings`.
    #
    # `min`/`max` default to h2..h3 because a page's h1 is usually the entry
    # title rendered by the layout, not part of the body outline.
    #
    # @param entry [Andromeda::Entry]
    # @param min [Integer] shallowest heading level to include.
    # @param max [Integer] deepest heading level to include.
    # @return [ActiveSupport::SafeBuffer] an empty string when nothing matches.
    def andromeda_toc(entry, min: 2, max: 3)
      headings = entry.headings.map { |heading| heading.transform_keys(&:to_sym) }
                      .select { |heading| heading[:depth].between?(min, max) }
      return "".html_safe if headings.empty?

      andromeda_toc_list(headings, min)
    end

    # Emits the meta tags an entry can fill in on its own. Anything needing
    # site-wide knowledge (og:image defaults, canonical host) belongs in the
    # application layout, which is why only these three are produced here.
    #
    # @param entry [Andromeda::Entry]
    # @param url [String, nil] canonical URL, when the caller knows it.
    # @return [ActiveSupport::SafeBuffer]
    def andromeda_meta_tags(entry, url: nil)
      data = entry.data
      tags = []
      tags << tag.title(data[:title]) if data[:title]
      tags << tag.meta(name: "description", content: data[:description]) if data[:description]
      tags << tag.link(rel: "canonical", href: url) if url
      safe_join(tags, "\n")
    end

    private

    # Builds one `<ul>` per heading level, descending only when the next
    # heading is deeper, so the markup mirrors the document outline. A nested
    # list belongs inside its parent `<li>`, which is why items are collected
    # as inner HTML and wrapped only once their children are known.
    def andromeda_toc_list(headings, depth)
      items = []

      while (heading = headings.first)
        break if heading[:depth] < depth

        if heading[:depth] > depth
          nested = andromeda_toc_list(headings, heading[:depth])
          items << (items.pop || "".html_safe) + nested
          next
        end

        headings.shift
        items << link_to(heading[:text], "##{heading[:slug]}")
      end

      tag.ul(safe_join(items.map { |item| tag.li(item) }, "\n"))
    end
  end
end
