//! Native Markdown/MDX parser for the `andromeda_cms` gem.
//!
//! Wraps Sätteri (the Rust engine Astro 7+ uses by default) to extract an
//! mdast tree as JSON. See `Cargo.toml` for why Sätteri.
//!
//! Parsing happens fully in Rust; the mdast tree crosses the FFI boundary as
//! a single JSON string rather than as nested Ruby objects, because building
//! Ruby `Hash`/`Array` objects node-by-node through the Ruby C API is far
//! slower than one `serde_json::to_string` + one `JSON.parse` on the Ruby
//! side (roughly comparable either way; JSON avoids also
//! having to hold the GVL while walking the arena).

mod errors;
mod nodes;

use magnus::{function, prelude::*, Error, Ruby};
use satteri_pulldown_cmark::{Options, DEFAULT_OPTIONS};
use std::panic;

/// Identifies the engine backing `Parser.parse`, so host apps and tests can
/// assert on it without depending on Sätteri internals directly.
fn parser_backend() -> String {
    "satteri".to_string()
}

fn options_for(mdx: bool) -> Options {
    // satteri-pulldown-cmark's own MDX_OPTIONS constant is just
    // `DEFAULT_OPTIONS | ENABLE_MDX` (arena_build.rs); it is not used
    // directly below because ENABLE_SMART_PUNCTUATION also needs adding to
    // both the MDX and non-MDX cases. DEFAULT_OPTIONS already turns on GFM (tables,
    // strikethrough, task lists, autolinks), footnotes, math, and YAML
    // frontmatter, matching Astro's `markdown.gfm` default of `true`
    // (`@astrojs/markdown-satteri`'s `features: { gfm: gfm !== false, ... }`).
    //
    // Deliberately NOT enabled, to stay compatible with what Astro actually
    // ships: ENABLE_HEADING_ATTRIBUTES (remark doesn't parse `# H {#id}`,
    // and Astro derives heading ids via a separate github-slugger pass, not
    // Sätteri), ENABLE_DIRECTIVE / ENABLE_DEFINITION_LIST / ENABLE_SUPERSCRIPT
    // / ENABLE_SUBSCRIPT (no remark-directive/remark-supersub equivalent in
    // Astro's default pipeline).
    //
    // ENABLE_SMART_PUNCTUATION:
    // Astro enables remark-smartypants unconditionally
    // (packages/internal-helpers/src/markdown.ts's `markdownConfigDefaults`),
    // but DEFAULT_OPTIONS does *not*
    // include it -- confirmed by reading satteri-pulldown-cmark's
    // arena_build.rs (`DEFAULT_OPTIONS` bitset has no
    // `ENABLE_SMART_PUNCTUATION`). It has to be turned on explicitly here so
    // straight quotes/dashes/ellipses in Markdown text get the same
    // curly-quote/em-dash/ellipsis substitution Astro's output has by
    // default; `Options::ENABLE_SMART_PUNCTUATION` is itself just
    // `ENABLE_SMART_QUOTES | ENABLE_SMART_DASHES | ENABLE_SMART_ELLIPSES`
    // (satteri-pulldown-cmark's lib.rs), which is exactly what
    // retext-smartypants' default options transform.
    let base = DEFAULT_OPTIONS | Options::ENABLE_SMART_PUNCTUATION;

    if mdx {
        base | Options::ENABLE_MDX
    } else {
        base
    }
}

/// `Andromeda::Parser.native_parse(source, mdx)` -> mdast JSON string.
///
/// Ruby-facing errors: `Andromeda::SyntaxError` (source could not be parsed,
/// carries line/column) or `Andromeda::ParserError` (Sätteri itself panicked).
/// See `lib/andromeda/parser.rb` for the public wrapper that attaches `path`.
///
/// Nesting is capped at `MAX_DEPTH` (see there for why).
/// Deeper trees are rejected as a syntax error instead of converted.
///
/// Converting the tree to JSON, and rendering it to HTML on the Ruby side,
/// are both recursive over nesting depth. A few thousand nested `>` or
/// `<div>` overflow the native stack, and on a Ruby thread other than the
/// main one -- which is where Puma serves development requests -- the stack
/// is small enough that 5,000 levels already fail. Real content nests a handful of levels; 256 leaves ample room for it
/// while keeping every recursive step far from any stack limit.
const MAX_DEPTH: usize = 256;

/// Longest run of a single `*` or `_` accepted.
///
/// Sätteri resolves emphasis recursively while parsing, before there is a
/// tree for `MAX_DEPTH` to inspect, so its depth has to be bounded from the
/// source instead. On a Puma thread a run of about 50,000 exhausts the
/// stack; no real document has a run anywhere near 10,000.
const MAX_DELIMITER_RUN: usize = 10_000;

/// Byte offset where the first over-long `*`/`_` run starts, if any.
fn overlong_delimiter_run(source: &str) -> Option<usize> {
    let bytes = source.as_bytes();
    let mut start = 0;
    for (index, &byte) in bytes.iter().enumerate() {
        if index == 0 || byte != bytes[index - 1] {
            start = index;
        }
        if (byte == b'*' || byte == b'_') && index - start + 1 > MAX_DELIMITER_RUN {
            return Some(start);
        }
    }
    None
}

fn rb_native_parse(ruby: &Ruby, source: String, mdx: bool) -> Result<String, Error> {
    if let Some(offset) = overlong_delimiter_run(&source) {
        let message = format!("a run of more than {MAX_DELIMITER_RUN} `*` or `_` characters is nested too deeply to parse");
        return Err(errors::syntax_error(ruby, &source, offset, &message)?);
    }

    let parsed = panic::catch_unwind(panic::AssertUnwindSafe(|| {
        satteri_pulldown_cmark::parse(&source, options_for(mdx))
    }));

    let (arena, mdx_errors) = match parsed {
        Ok(pair) => pair,
        // Sätteri is pre-1.0 (see Cargo.toml); a panic must not abort the
        // whole Ruby process, so it is converted into a normal exception.
        Err(payload) => return Err(errors::parser_error(ruby, payload.as_ref())?),
    };

    if let Some((offset, message)) = mdx_errors.first() {
        return Err(errors::syntax_error(ruby, &source, *offset, message)?);
    }

    if let Some(id) = nodes::first_node_deeper_than(&arena, 0, MAX_DEPTH) {
        let offset = arena.get_node(id).start_offset as usize;
        let message = format!("content is nested more than {MAX_DEPTH} levels deep");
        return Err(errors::syntax_error(ruby, &source, offset, &message)?);
    }

    let json = nodes::node_to_json(&arena, 0);
    serde_json::to_string(&json)
        .map_err(|e| Error::new(ruby.exception_runtime_error(), e.to_string()))
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let namespace = ruby.define_module("Andromeda")?;
    let parser = namespace.define_module("Parser")?;
    parser.define_singleton_method("backend", function!(parser_backend, 0))?;
    parser.define_singleton_method("native_parse", function!(rb_native_parse, 2))?;
    Ok(())
}
