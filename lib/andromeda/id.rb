# frozen_string_literal: true

module Andromeda
  # Entry id generation, faithful to Astro's `glob()` loader:
  #
  #   1. A frontmatter `slug:` wins verbatim -- it is used as-is, not
  #      re-slugified, so an author can deliberately keep an id that is not
  #      slug-shaped (spaces, uppercase, whatever).
  #   2. Otherwise the extension is stripped from the path (relative to the
  #      collection's `base`), each `/`-separated segment is run through
  #      github-slugger, and the segments are rejoined with `/`.
  #   3. A trailing `index` segment is dropped, so directory-style entries
  #      (`posts/hello/index.mdx`) collapse onto their directory
  #      (`posts/hello`).
  #
  # Duplicate-id detection is deliberately NOT this module's job -- it needs
  # to see every file in a collection at once, which only Loader can do.
  module Id
    module_function

    # @param relative_path [String] entry path relative to the collection's
    #   `base`, extension included (e.g. "Guides/Getting Started.md").
    # @param slug [Object, nil] the raw frontmatter `slug:` value, if any
    #   (String-keyed, straight out of Andromeda::Frontmatter.parse -- not
    #   validated Schema output, since `slug` need not be a declared
    #   attribute).
    # @return [String]
    def generate(relative_path, slug: nil)
      return slug.to_s if slug_override?(slug)

      without_extension = relative_path.to_s.sub(/\.[^.\/\\]+\z/, "")
      segments = without_extension.split(%r{[/\\]}).reject(&:empty?)

      # A fresh Slugger per segment: its dedup counters (`-1`, `-2`, ...)
      # exist to disambiguate headings repeated within one document, not
      # path segments -- sharing one instance across an entire directory
      # tree would silently rename a second `guides/guides.md`-shaped
      # collision instead of letting the Loader's duplicate-id check catch
      # it as the error it actually is.
      slugged = segments.map { |segment| Andromeda::Slugger.new.slug(segment) }
      # Astro strips a trailing `index` only when a directory precedes it
      # (its rule is `replace(/\/index$/, "")`), so a collection's own
      # `index.md` keeps the id "index" instead of collapsing to "".
      slugged.pop if slugged.size > 1 && slugged.last == "index"
      slugged.join("/")
    end

    # Astro tests `if (data.slug)`, so every JavaScript-falsy value -- not
    # just a missing key -- falls back to the path. A blanked-out `slug: ""`
    # left over from a template must not become an empty id.
    def slug_override?(slug)
      return false if slug.nil? || slug == false || slug == ""
      return false if slug.is_a?(Numeric) && (slug.zero? || (slug.is_a?(Float) && slug.nan?))

      true
    end
  end
end
