# Andromeda

Astro-compatible content collections for Ruby on Rails.

https://github.com/user-attachments/assets/7bde3b4f-7bdb-49f9-9646-cd981846a451

[Documentation](https://www.andromedacms.dev/docs) · [Changelog](CHANGELOG.md)

Copy the `.md` and `.mdx` files from an [Astro](https://astro.build) project
into `app/content/`, and Andromeda validates their frontmatter against a schema
and renders them as ordinary Rails pages. The heavy work — parsing Markdown and
MDX and expanding components — happens once at deploy time; requests only read
the result.

> **Status: pre-release.** The API is not stable yet.

## Why

Adding a blog, docs or a marketing site to a Rails app has usually meant one of
three things: standing up a separate Astro or Next.js project, installing a CMS
gem with its own tables and admin screens, or wiring up a headless CMS over
HTTP. Andromeda takes Astro's content model — collections, schemas, MDX
components — and makes it a gem, so the content lives next to the application
that already has your authentication, your layouts and your deploy pipeline.

### Files are the interface

Those three options all put content behind a database and a screen. That made
sense while people were the only ones writing. They are not any more: much of
the writing, editing and restructuring now happens with an assistant in the
loop, and an assistant is good at exactly one thing here — reading and writing
files in a repository it can already see. Pointing it at a CMS means first
building it an API or an MCP server, giving that its own authentication, and
keeping it in sync with the schema. A second system, to serve the first.

Content as files needs none of that. Adding a post is adding a file, editing
one is an edit, removing one is `rm`. The change arrives as a diff, is reviewed
like any other, and ships with the deploy that carried it — and the tool doing
the writing needs no integration at all, because it already has the repository.
Of everything in Astro's design, this is the part that looks most like where
things are going.

### Alongside Astro, not against it

I like [Astro](https://astro.build), and I have a great deal of respect for the
team behind it. For a static site I still reach for it. But when a site needs
sessions, forms, background jobs and a database, I want Rails. Andromeda exists
so that this is not a choice between the two: the collection stays the same
directory of files, parsed by the same engine Astro 7 uses, and moving it into
Rails is a copy.

## Installation

```ruby
# Gemfile
gem "andromeda_cms"
```

```bash
bundle install
bin/rails generate andromeda:install
```

Ruby 3.2+ and Rails 8.0+. The gem ships precompiled binaries for common
platforms, so no Rust toolchain is needed to install it.

## Getting started

```bash
bin/rails generate andromeda:collection blog title:string pub_date:date
```

That writes an entry class, a controller, views, a route and a first post:

```ruby
# app/models/content/blog.rb
module Content
  class Blog < Andromeda::Entry
    collection :blog, base: "app/content/blog", pattern: "**/*.{md,mdx}"

    attribute :title, :string
    attribute :pub_date, :date

    # scope :published, -> { where(draft: false) }
  end
end
```

```ruby
# app/controllers/blog_controller.rb
class BlogController < ApplicationController
  def index
    @entries = Content::Blog.all.order(pub_date: :desc)
  end

  def show
    @entry = Content::Blog.find(params[:slug])
  end
end
```

```erb
<%# app/views/blog/show.html.erb %>
<article>
  <h1><%= @entry.title %></h1>
  <%= andromeda_content @entry %>
</article>
```

From there it is your code. A typical next step is to make fields mandatory,
add a draft flag, and add a table of contents:

```ruby
attribute :title, :string, required: true
attribute :pub_date, :date, required: true
attribute :draft, :boolean, default: false

scope :published, -> { where(draft: false) }
```

```erb
<%= andromeda_toc @entry %>
```

An unknown slug raises `Andromeda::EntryNotFound`, which Rails answers with a
404.

Pages are ordinary Rails, so layouts, `current_user`, CSRF tokens, caching and
authorization all behave exactly as they normally do.

## Content

```markdown
---
title: Hello world
pub_date: 2026-09-01
tags: [rails, astro]
---

## Getting started

Ordinary GFM Markdown, with smart punctuation and syntax highlighting.
```

Frontmatter is validated against the entry class: a missing `title` or an
unparseable date fails the build with the file name and line number, rather
than surfacing as `nil` in a view.

### MDX components

MDX components map to Rails partials — no ViewComponent dependency:

```mdx
import Callout from 'content_components/callout';

<Callout type="tip" title="Note">
  The body is **Markdown** too.
</Callout>
```

```erb
<%# app/views/content_components/_callout.html.erb %>
<aside class="callout callout--<%= local_assigns.fetch(:type, "note") %>">
  <% if local_assigns[:title] %><p class="callout__title"><%= title %></p><% end %>
  <%= content %>
</aside>
```

Props arrive as locals (`camelCase` becomes `snake_case`), the tag's children
arrive as `content`, and `<Fragment slot="header">` becomes a `header` local.
`content` is passed even to a self-closing tag (`<Callout />`), so a partial
using strict locals must declare it:

```erb
<%# locals: (type: "note", title: nil, content: nil) %>
```

`bin/rails generate andromeda:component Callout type title` writes the stub.

A component can query other entries, e.g. a card linking to another post:

```erb
<%# app/views/content_components/_post_card.html.erb %>
<%# locals: (slug:, content: nil) %>
<% post = Content::Blog.find(slug) %>
<a href="<%= blog_path(post.id) %>">
  <img src="<%= andromeda_image_url(post.cover_image) %>" alt="">
  <%= post.title %>
</a>
```

During `andromeda:build` such queries read the source files, so an entry not
converted yet is still found, and `andromeda_content(post)` converts it on
the spot. Component HTML is rendered once at build time
and stored, so `andromeda_image_url` emits a placeholder there that
`andromeda_content` turns into the digest-stamped URL when the page is served.

### Images

Put an image next to the entry and reference it relatively:

```
app/content/blog/my-post/
├── index.md
└── cover.png
```

```markdown
![Cover](./cover.png)
```

Referenced images are copied into `app/assets/builds/andromeda/` during the
build and served, digest-stamped, by the asset pipeline. Images the app
already ships (`app/assets/images/logo.png`, written as `logo.png`) resolve
through the pipeline too; anything under `public/` or on another host is left
untouched. Declare a frontmatter image with `attribute :hero_image, :image`
and render it with `andromeda_image_url`.

To pass an image to a component, import it and use it as a prop, as in Astro:

```mdx
import photo from './photo.png';

<Figure src={photo} caption="The view from the top" />
```

The partial receives the same `Andromeda::Image` an `image` attribute holds:

```erb
<%# locals: (src:, caption: nil, content: nil) %>
<figure>
  <img src="<%= andromeda_image_url(src) %>" class="w-full" alt="">
  <figcaption><%= caption %></figcaption>
</figure>
```

`image_tag andromeda_image_url(src)` works as well: while converting, the
asset helpers pass the placeholder through untouched.

## Development and deployment

```
development:  request → entry is converted on demand when its source changed
production:   deploy  → andromeda:build writes .andromeda/, requests only read it
```

There is no watcher process to run: in development a file is converted the
first time something asks for it after it changes. In production the parser
never runs while serving a request, and an unbuilt entry raises an error that
names the fix instead of silently converting.

`andromeda:build` is hooked into `assets:precompile`, so the Rails 8 Dockerfile
(and Kamal, and Heroku) already runs it. `.andromeda/` is a build artifact:
the installer adds it to `.gitignore` and `.dockerignore`.

| Task | What it does |
|------|--------------|
| `andromeda:build` | Convert every entry into `.andromeda/` (runs during `assets:precompile`) |
| `andromeda:check` | Report schema problems, missing components and non-snake_case keys; writes nothing (for CI) |
| `andromeda:fix` | Rewrite non-snake_case frontmatter keys in place |
| `andromeda:clobber` | Remove `.andromeda/` (runs during `assets:clobber`) |

## Migrating from Astro

```bash
bin/rails generate andromeda:import_astro ../my-astro-site
```

It copies `src/content` and `src/assets`, rewrites frontmatter keys to
snake_case and MDX imports to partial paths, converts `content.config.ts` into
entry classes, generates stubs for the components your content imports, and
prints what still needs a human. `--dry-run` shows the plan without writing.

Astro's own [`examples/blog`](https://github.com/withastro/astro/tree/main/examples/blog)
imports and renders unchanged; that is a test in this repository.

## Compatibility

Andromeda targets Astro 7 and later and uses
[Sätteri](https://github.com/bruits/satteri) — the Markdown and MDX engine
Astro 7 uses by default — so content is parsed by the same engine that parsed
it in Astro. Heading ids use github-slugger, `headings` has the same shape as
Astro's `render()`, and entry ids follow Astro's `glob()` loader rules.

The goal is that content copied from an Astro project loads without errors and
displays. Byte-identical output is a non-goal: syntax highlighting uses Rouge
rather than Shiki (same markup shape, approximate colours), and images are
served by the asset pipeline rather than Astro's image service.

Not supported: Astro's pages and routing, islands and `client:*` directives,
remark/rehype plugins, and arbitrary JavaScript in MDX expressions (literals,
`{frontmatter.x}` and comments are evaluated; anything else is an error rather
than a silent drop).

## Development

```bash
bin/setup            # or: bundle install
bundle exec rake     # compiles the Rust extension, then runs the tests
bundle exec rake test:corpus  # after test/fetch_corpus.sh: parse ~370 real Astro files
```

## Troubleshooting

**`ArgumentError: wrong number of arguments (given 2, expected 1)` from `JSON.parse`.**
Not this gem: Rails 8.1 calls `JSON.parse` with a positional options hash, which
version 3 of the `json` gem no longer accepts, and decrypting a session cookie
hits that path — so pages fail only once a session exists. Pin the `json` gem
until Rails ships a fix:

```ruby
# Gemfile
gem "json", "~> 2.9"
```

## Contributing

Bug reports are welcome; patches are not. Andromeda is open source but not open
contribution — see [CONTRIBUTING.md](CONTRIBUTING.md) for why, and for what a
useful bug report contains.

## License

Copyright (c) 2026 [LIMHAUS Inc.](https://www.limhaus.com/). Released under the [MIT License](LICENSE.txt).
