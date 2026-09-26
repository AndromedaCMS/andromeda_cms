//! Converts Sätteri parse failures into the `Andromeda::*` exception classes
//! that Ruby callers already know about (see `lib/andromeda/errors.rb`).
//!
//! Rust raises the real Ruby classes directly (rather than a generic
//! `RuntimeError`) so `rescue Andromeda::SyntaxError` works without the Ruby
//! wrapper having to re-wrap every native call. The classes are looked up by
//! name through `Ruby#eval` instead of being cached, because construction
//! only happens on the (rare) error path — the ~0.3ms/file hot path never
//! touches this module.

use magnus::{kwargs, Class, Error, ExceptionClass, Ruby};
use satteri_arena::LineIndex;
use std::any::Any;

/// Builds an `Andromeda::SyntaxError` from a Sätteri MDX error.
///
/// Sätteri reports errors as `(byte_offset, message)` pairs with no line/
/// column of their own, so we re-derive them from the same `LineIndex` the
/// parser itself uses (1-based line/column, matching `ArenaNode`'s fields).
///
/// `path` is intentionally not set here: the native layer has no notion of
/// "which file is this" — `Andromeda::Parser.parse` (Ruby) re-raises with
/// `path:` attached once it knows it.
pub fn syntax_error(ruby: &Ruby, source: &str, offset: usize, message: &str) -> Result<Error, Error> {
    let index = LineIndex::from_source(source);
    let mut cursor = index.cursor();
    let (line, column) = cursor.offset_to_line_col(offset as u32);

    let class: ExceptionClass = ruby.eval("Andromeda::SyntaxError")?;
    let exception = class.new_instance((message, kwargs!(ruby, "line" => line, "column" => column)))?;
    Ok(Error::from(exception))
}

/// Builds an `Andromeda::ParserError` from a caught Rust panic payload.
///
/// Sätteri is pre-1.0 (see Cargo.toml comment); a panic here must not abort
/// the whole Ruby process, so callers wrap the parse in `catch_unwind` and
/// hand the payload to this function instead of letting it unwind past the
/// FFI boundary (which would be undefined behavior).
pub fn parser_error(ruby: &Ruby, payload: &(dyn Any + Send)) -> Result<Error, Error> {
    let message = payload
        .downcast_ref::<&str>()
        .map(|s| s.to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "the native Markdown/MDX parser panicked".to_string());

    let class: ExceptionClass = ruby.eval("Andromeda::ParserError")?;
    Ok(Error::new(class, message))
}
