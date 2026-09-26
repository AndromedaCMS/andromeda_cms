//! Walks a Sätteri `Arena<Mdast>` and renders it as mdast-spec-shaped JSON.
//!
//! This hand-written decode (rather than `#[derive(Serialize)]`) is
//! necessary: Sätteri stores node-specific fields as a binary
//! `#[repr(C)]` blob (`type_data`) rather than an idiomatic Rust enum, so
//! each node type needs its own `XxxData::from_bytes` call
//! (`satteri-ast`'s design targets its own napi/TS layer, not
//! third-party Rust embedders).
//!
//! Every node here also carries a unist `position`
//! (start/end line, column, offset). The gem needs
//! line numbers to build `path:line:column: message` errors, so positions
//! are not optional here.

use satteri_arena::{decode_string_ref_data, Arena, Mdast, StringRef};
use satteri_ast::mdast::codec::*;
use satteri_ast::mdast::MdastNodeType;
use serde_json::{json, Map, Value};

fn get_str(arena: &Arena<Mdast>, sr: StringRef) -> String {
    arena.get_str(sr).to_string()
}

fn opt_str(arena: &Arena<Mdast>, sr: StringRef) -> Value {
    if sr.is_empty() {
        Value::Null
    } else {
        Value::String(get_str(arena, sr))
    }
}

/// unist `Position`: 1-based line/column (as Sätteri's `LineIndex` computes
/// them — UTF-16-code-unit columns, matching what remark/unist report) and a
/// byte offset (Sätteri does not track a separate UTF-16 offset per node, so
/// `offset` is a byte index here; this is the one field that does not match
/// mdast-util-from-markdown exactly, and only matters for tooling that
/// slices `source[start.offset...end.offset]` on non-ASCII input).
fn position(arena: &Arena<Mdast>, id: u32) -> Value {
    let node = arena.get_node(id);
    json!({
        "start": {
            "line": node.start_line,
            "column": node.start_column,
            "offset": node.start_offset,
        },
        "end": {
            "line": node.end_line,
            "column": node.end_column,
            "offset": node.end_offset,
        },
    })
}

/// Whether mdast-util-from-markdown would emit a `children` array for this
/// node type, even when empty (a unist `Parent`) as opposed to leaving it
/// out entirely (a unist `Literal`/leaf). Kept as an explicit allow-list
/// rather than "non-empty children" so an empty paragraph/root/etc still
/// round-trips as `children: []` instead of silently losing the field.
fn is_parent(nt: MdastNodeType) -> bool {
    matches!(
        nt,
        MdastNodeType::Root
            | MdastNodeType::Paragraph
            | MdastNodeType::Heading
            | MdastNodeType::Emphasis
            | MdastNodeType::Strong
            | MdastNodeType::Delete
            | MdastNodeType::Blockquote
            | MdastNodeType::List
            | MdastNodeType::ListItem
            | MdastNodeType::Link
            | MdastNodeType::LinkReference
            | MdastNodeType::Table
            | MdastNodeType::TableRow
            | MdastNodeType::TableCell
            | MdastNodeType::FootnoteDefinition
            | MdastNodeType::Superscript
            | MdastNodeType::Subscript
            | MdastNodeType::ContainerDirective
            | MdastNodeType::LeafDirective
            | MdastNodeType::TextDirective
            | MdastNodeType::DescriptionList
            | MdastNodeType::DescriptionTerm
            | MdastNodeType::DescriptionDetails
            | MdastNodeType::MdxJsxFlowElement
            | MdastNodeType::MdxJsxTextElement
    )
}

/// Best-effort decode of a node's `type_data` into JSON fields, keyed by
/// mdast-spec field names. Node types not covered here (e.g. `thematicBreak`,
/// `break`) have no extra fields in the spec either, so they fall through to
/// `{}`.
fn type_fields(arena: &Arena<Mdast>, id: u32, nt: MdastNodeType) -> Value {
    let data = arena.get_type_data(id);
    match nt {
        MdastNodeType::Text
        | MdastNodeType::InlineCode
        | MdastNodeType::Html
        | MdastNodeType::Yaml
        | MdastNodeType::Toml
        | MdastNodeType::MdxFlowExpression
        | MdastNodeType::MdxTextExpression
        | MdastNodeType::MdxjsEsm => {
            if data.is_empty() {
                json!({ "value": "" })
            } else {
                let sr = decode_string_ref_data(data);
                json!({ "value": get_str(arena, sr) })
            }
        }
        MdastNodeType::Math | MdastNodeType::InlineMath => {
            if data.len() >= 16 {
                let d = MathData::from_bytes(data);
                json!({
                    "meta": opt_str(arena, d.meta),
                    "value": get_str(arena, d.value),
                })
            } else {
                json!({})
            }
        }
        MdastNodeType::Heading => {
            if !data.is_empty() {
                json!({ "depth": data[0] })
            } else {
                json!({})
            }
        }
        MdastNodeType::Link => {
            if !data.is_empty() {
                let d = LinkData::from_bytes(data);
                json!({
                    "url": get_str(arena, d.url),
                    "title": opt_str(arena, d.title),
                })
            } else {
                json!({})
            }
        }
        MdastNodeType::Image => {
            if !data.is_empty() {
                let d = ImageData::from_bytes(data);
                json!({
                    "url": get_str(arena, d.url),
                    "alt": opt_str(arena, d.alt),
                    "title": opt_str(arena, d.title),
                })
            } else {
                json!({})
            }
        }
        MdastNodeType::Code => {
            if !data.is_empty() {
                let d = CodeData::from_bytes(data);
                json!({
                    "lang": opt_str(arena, d.lang),
                    "meta": opt_str(arena, d.meta),
                    "value": get_str(arena, d.value),
                })
            } else {
                json!({})
            }
        }
        MdastNodeType::List => {
            if !data.is_empty() {
                let d = ListData::from_bytes(data);
                json!({
                    "ordered": d.ordered,
                    "start": if d.ordered { Value::from(d.start) } else { Value::Null },
                    "spread": d.spread,
                })
            } else {
                json!({})
            }
        }
        MdastNodeType::ListItem => {
            if !data.is_empty() {
                let d = ListItemData::from_bytes(data);
                json!({
                    "checked": match d.checked { 0 => Value::Bool(false), 1 => Value::Bool(true), _ => Value::Null },
                    "spread": d.spread,
                })
            } else {
                json!({})
            }
        }
        MdastNodeType::DescriptionDetails => {
            if !data.is_empty() {
                let d = DescriptionDetailsData::from_bytes(data);
                json!({ "spread": d.spread })
            } else {
                json!({})
            }
        }
        MdastNodeType::LinkReference
        | MdastNodeType::ImageReference
        | MdastNodeType::FootnoteReference => {
            if !data.is_empty() {
                let d = ReferenceData::from_bytes(data);
                let kind = match d.reference_kind {
                    0 => "shortcut",
                    1 => "collapsed",
                    _ => "full",
                };
                let mut fields = Map::new();
                fields.insert(
                    "identifier".into(),
                    Value::String(get_str(arena, d.identifier)),
                );
                fields.insert("label".into(), opt_str(arena, d.label));
                // mdast spec: only link/imageReference carry referenceType,
                // not footnoteReference.
                if nt != MdastNodeType::FootnoteReference {
                    fields.insert("referenceType".into(), Value::String(kind.into()));
                }
                // imageReference alone also carries `alt`, stored as a trailing
                // StringRef appended after the shared ReferenceData header (see
                // satteri_ast::mdast::codec::encode_image_reference_data).
                if nt == MdastNodeType::ImageReference {
                    let alt = decode_image_reference_alt(data);
                    fields.insert("alt".into(), opt_str(arena, alt));
                }
                Value::Object(fields)
            } else {
                json!({})
            }
        }
        MdastNodeType::FootnoteDefinition => {
            if !data.is_empty() {
                let d = FootnoteDefinitionData::from_bytes(data);
                json!({
                    "identifier": get_str(arena, d.identifier),
                    "label": opt_str(arena, d.label),
                })
            } else {
                json!({})
            }
        }
        MdastNodeType::Definition => {
            if !data.is_empty() {
                let d = DefinitionData::from_bytes(data);
                json!({
                    "url": get_str(arena, d.url),
                    "title": opt_str(arena, d.title),
                    "identifier": get_str(arena, d.identifier),
                    "label": opt_str(arena, d.label),
                })
            } else {
                json!({})
            }
        }
        MdastNodeType::Table => {
            // TableData header (align_count: u32) followed by align_count
            // ColumnAlign bytes (see satteri_ast::mdast::codec::TableData).
            if data.len() >= 4 {
                let count = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
                let mut aligns = vec![];
                for i in 0..count {
                    let b = *data.get(4 + i).unwrap_or(&0);
                    aligns.push(match b {
                        1 => Value::String("left".into()),
                        2 => Value::String("right".into()),
                        3 => Value::String("center".into()),
                        _ => Value::Null,
                    });
                }
                json!({ "align": aligns })
            } else {
                json!({})
            }
        }
        MdastNodeType::ContainerDirective
        | MdastNodeType::LeafDirective
        | MdastNodeType::TextDirective => {
            if data.len() >= 12 {
                let name = decode_directive_name(data);
                let attr_count = decode_directive_attr_count(data);
                let mut attrs = Map::new();
                for i in 0..attr_count {
                    let (key, value) = decode_directive_attr(data, i);
                    attrs.insert(get_str(arena, key), Value::String(get_str(arena, value)));
                }
                json!({
                    "name": get_str(arena, name),
                    "attributes": attrs,
                })
            } else {
                json!({})
            }
        }
        MdastNodeType::MdxJsxFlowElement | MdastNodeType::MdxJsxTextElement => {
            if data.len() >= 16 {
                let name_sr = decode_mdx_jsx_element_name(data);
                let attr_count = decode_mdx_jsx_attr_count(data);
                let name = if name_sr.is_empty() {
                    Value::Null // fragment (<>...</>)
                } else {
                    Value::String(get_str(arena, name_sr))
                };
                let mut attrs = vec![];
                for i in 0..attr_count {
                    let (kind, attr_name, attr_value) = decode_mdx_jsx_attr(data, i);
                    if kind == 3 {
                        // spread ({...expr}): no name, value is the raw
                        // expression text.
                        attrs.push(json!({
                            "type": "mdxJsxExpressionAttribute",
                            "value": get_str(arena, attr_value),
                        }));
                        continue;
                    }
                    let value = match kind {
                        0 => Value::Null,                               // boolean prop
                        1 => Value::String(get_str(arena, attr_value)), // literal
                        _ => {
                            json!({ "type": "mdxJsxAttributeValueExpression", "value": get_str(arena, attr_value) })
                        } // expression prop
                    };
                    attrs.push(json!({
                        "type": "mdxJsxAttribute",
                        "name": get_str(arena, attr_name),
                        "value": value,
                    }));
                }
                json!({ "name": name, "attributes": attrs })
            } else {
                json!({ "name": Value::Null, "attributes": Value::Array(vec![]) })
            }
        }
        MdastNodeType::Custom => {
            if data.len() >= 16 {
                let name = StringRef::from_bytes(&data[0..8]);
                let value = StringRef::from_bytes(&data[8..16]);
                json!({
                    "customType": get_str(arena, name),
                    "value": opt_str(arena, value),
                })
            } else {
                json!({})
            }
        }
        _ => json!({}),
    }
}

/// The first node (in document order) that sits more than `limit` levels
/// below `root`, if any.
///
/// Deliberately iterative: it runs before the recursive `node_to_json`, so
/// it must not be the thing that overflows the stack on the input it exists
/// to reject.
pub fn first_node_deeper_than(arena: &Arena<Mdast>, root: u32, limit: usize) -> Option<u32> {
    let mut pending = vec![(root, 0usize)];
    while let Some((id, depth)) = pending.pop() {
        if depth > limit {
            return Some(id);
        }
        let parent = MdastNodeType::from_u8(arena.get_node(id).node_type).is_some_and(is_parent);
        if parent {
            pending.extend(
                arena
                    .get_children(id)
                    .iter()
                    .rev()
                    .map(|&child| (child, depth + 1)),
            );
        }
    }
    None
}

/// Recursively renders one arena node (and its subtree) as mdast JSON.
pub fn node_to_json(arena: &Arena<Mdast>, id: u32) -> Value {
    let node = arena.get_node(id);
    let nt = MdastNodeType::from_u8(node.node_type);
    let type_name = nt.map(|t| t.name()).unwrap_or("unknown").to_string();

    let mut obj = Map::new();
    obj.insert("type".into(), Value::String(type_name));
    if let Some(nt) = nt {
        if let Value::Object(fields) = type_fields(arena, id, nt) {
            for (k, v) in fields {
                obj.insert(k, v);
            }
        }
    }

    if let Some(nt) = nt {
        if is_parent(nt) {
            let children = arena.get_children(id);
            let arr: Vec<Value> = children.iter().map(|&c| node_to_json(arena, c)).collect();
            obj.insert("children".into(), Value::Array(arr));
        }
    }

    obj.insert("position".into(), position(arena, id));

    Value::Object(obj)
}
