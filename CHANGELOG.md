# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `image_tag andromeda_image_url(src)` in a component no longer fails
  `andromeda:build` with `Propshaft::MissingAssetError`. While converting,
  the asset helpers (`image_tag`, `asset_path`, `asset_url`...) pass an asset
  marker through untouched, so `andromeda_content` resolves it when the page
  is served.

## [0.4.0] - 2026-09-29

### Added

- An image imported in MDX (`import photo from './photo.png'`) can be passed
  to a component as a prop (`<Figure src={photo} />`). It is published like
  an `image` attribute, and the partial receives an `Andromeda::Image`.
- `rails g andromeda:component` writes a strict locals declaration that
  includes `content: nil`, since `content` is passed even to a self-closing
  tag.

### Fixed

- A component that queries entries (`Content::Post.find(slug)`) during
  `andromeda:build` in production reads source files instead of the
  previous build's `_index.json`, so an entry not converted yet is found.
- `andromeda_image_url` called inside a component while converting returns
  an asset marker instead of a URL without a digest, which 404'd in
  production. `andromeda_content` leaves markers in place there too.
- A component that renders another entry's HTML during `andromeda:build`
  converts that entry on the spot when it has not been converted yet,
  instead of raising `Andromeda::BuildMissing`. Entries whose components
  render each other fail with a "circular conversion" error.
- An `Andromeda::Error` raised inside a component partial (such as
  `EntryNotFound` from `find`) is no longer wrapped in
  `ActionView::Template::Error`, so the build lists it with the other
  problems instead of aborting with a stack trace.

## [0.3.0] - 2026-09-29

### Added

- `offset(count)` on `Andromeda::Relation` and on `Andromeda::Entry`
  subclasses skips the first `count` entries, so `offset(10).limit(10)`
  pages through a listing without leaving the relation.

## [0.2.0] - 2026-09-29

### Changed

- The reader for an `:array` attribute declared `of: :reference` now resolves
  each element to its entry, the way a single `:reference` reader already
  did: `post.tags` returns the tag entries, in frontmatter order, and raises
  `Andromeda::EntryNotFound` for an id with no entry. It used to return the
  `Andromeda::Reference` pointers, which are still in `post.data[:tags]`.
- `andromeda:build` and `andromeda:check` now fail on content that used to
  pass and then broke when served. Run `andromeda:check` before upgrading a
  deploy to see what needs fixing:
  - a `:reference`, alone or in an array, whose id has no entry in the target
    collection, or that names a collection nobody registered;
  - an image in the body written as a bare path (`blog/posts/x.png`) that
    Propshaft's load path cannot find. These used to fall back to a plain
    `/assets/...` URL and 404 in production. Without Propshaft the path is
    still used as written.
- Declaring `:array` with `of: :reference` and no `collection:`, or with
  `of: :enum` and no `values:`, now raises `ArgumentError` at definition time.

### Fixed

- An `:array` of `:reference` built its elements without the declared
  `collection:`, so each `Andromeda::Reference` had a `nil` collection. The
  first process worked; the next one to read `.andromeda/` failed with
  `NoMethodError: undefined method 'to_sym' for nil`. `of: :enum` lost its
  `values:` the same way and raised `NoMethodError` on any value.
- An image in the body written as `./` or `../` with no file behind it was
  treated as an asset pipeline path and rendered as a broken `/assets/./...`
  URL. It now fails the build, as the documentation says, and so does a
  relative path that leaves the project.
- `andromeda:install` appended its ignore lines to the last line of a
  `.gitignore` or `.dockerignore` that did not end with a newline, breaking
  both that entry and `/.andromeda/`.

## [0.1.2] - 2026-09-27

### Fixed

- `Entry#body` returned `nil` in production. Entries there are read from the
  built index, which leaves bodies out, so anything using the raw Markdown --
  a reading-time estimate, a Markdown export -- failed with `NoMethodError`.
  The build now stores each entry's body in its own file (not the index), and
  `Entry#body` reads it from there when needed, the same way `html` works.
  Existing builds pick this up on the next `andromeda:build`.

## [0.1.1] - 2026-09-27

### Fixed

- `andromeda:build` failed with `Andromeda::BuildMissing` when run in
  production mode on a clean checkout -- which is exactly how
  `assets:precompile` runs in a Docker build -- because it listed entries from
  the built index instead of the source files. On a production machine that
  already had a build, the same path would have rewritten every page with an
  empty body. Builds now always read the source files.

## [0.1.0] - 2026-09-27

### Added

- Astro-compatible content collections: entry classes with a schema DSL, an
  Astro-compatible id scheme, and queries (`all`/`find`/`where`/`order`/scopes).
- Markdown and MDX conversion through Sätteri, the engine Astro 7 uses by
  default, with GFM, smart punctuation, github-slugger heading ids and Rouge
  syntax highlighting.
- MDX components rendered as Rails partials, including props, children and
  named slots.
- Frontmatter parsing with Astro-compatible semantics: YAML 1.2 scalars, TOML
  (`+++`), and line numbers preserved for error messages.
- Build pipeline: `andromeda:build` (hooked into `assets:precompile`),
  `andromeda:check`, `andromeda:fix` and `andromeda:clobber`, writing to
  `.andromeda/`; on-demand conversion in development.
- Images referenced from content published through the asset pipeline.
- View helpers: `andromeda_content`, `andromeda_toc`, `andromeda_meta_tags`,
  `andromeda_image_url`.
- Generators: `andromeda:install`, `andromeda:collection`,
  `andromeda:component` and `andromeda:import_astro`.

[0.4.0]: https://github.com/AndromedaCMS/andromeda_cms/releases/tag/v0.4.0
[0.3.0]: https://github.com/AndromedaCMS/andromeda_cms/releases/tag/v0.3.0
[0.2.0]: https://github.com/AndromedaCMS/andromeda_cms/releases/tag/v0.2.0
[0.1.2]: https://github.com/AndromedaCMS/andromeda_cms/releases/tag/v0.1.2
[0.1.1]: https://github.com/AndromedaCMS/andromeda_cms/releases/tag/v0.1.1
[0.1.0]: https://github.com/AndromedaCMS/andromeda_cms/releases/tag/v0.1.0
