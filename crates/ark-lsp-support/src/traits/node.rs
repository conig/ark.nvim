//
// node.rs
//
// Copyright (C) 2022-2026 Posit Software, PBC. All rights reserved.
//
//

use anyhow::anyhow;
use stdext::all;
use stdext::result::ResultExt;
use tree_sitter::Node;
use tree_sitter::Point;
use tree_sitter::Range;
use tree_sitter::TreeCursor;

use crate::traits::point::PointExt;

fn _dump_impl(cursor: &mut TreeCursor, source: &str, indent: &str, output: &mut String) {
    let node = cursor.node();

    if node.start_position().row == node.end_position().row {
        output.push_str(
            format!(
                "{} - {} - {} ({} -- {})\n",
                indent,
                node.node_as_str(source).unwrap(),
                node.kind(),
                node.start_position(),
                node.end_position(),
            )
            .as_str(),
        );
    }

    if cursor.goto_first_child() {
        let indent = format!("  {}", indent);
        _dump_impl(cursor, source, indent.as_str(), output);
        while cursor.goto_next_sibling() {
            _dump_impl(cursor, source, indent.as_str(), output);
        }

        cursor.goto_parent();
    }
}

pub struct FwdLeafIterator<'a> {
    pub node: Node<'a>,
}

impl<'a> Iterator for FwdLeafIterator<'a> {
    type Item = Node<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(node) = self.node.next_leaf() {
            self.node = node;
            Some(node)
        } else {
            None
        }
    }
}

pub struct BwdLeafIterator<'a> {
    pub node: Node<'a>,
}

impl<'a> Iterator for BwdLeafIterator<'a> {
    type Item = Node<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(node) = self.node.prev_leaf() {
            self.node = node;
            Some(node)
        } else {
            None
        }
    }
}

pub trait NodeExt: Sized {
    fn dump(&self, source: &str) -> String;

    fn find_parent(&self, callback: impl Fn(&Self) -> bool) -> Option<Self>;

    fn find_smallest_spanning_node(&self, point: Point) -> Option<Self>;
    fn find_closest_node_to_point(&self, point: Point) -> Option<Self>;

    fn prev_leaf(&self) -> Option<Self>;
    fn next_leaf(&self) -> Option<Self>;

    fn fwd_leaf_iter(&self) -> FwdLeafIterator<'_>;
    fn bwd_leaf_iter(&self) -> BwdLeafIterator<'_>;

    fn ancestors(&self) -> impl Iterator<Item = Self>;
    fn children_of(node: Self) -> impl Iterator<Item = Self>;
    fn next_siblings(&self) -> impl Iterator<Item = Self>;
    fn arguments(&self) -> impl Iterator<Item = (Option<Self>, Option<Self>)>;
    fn arguments_values(&self) -> impl Iterator<Item = Option<Self>>;
    fn arguments_names(&self) -> impl Iterator<Item = Option<Self>>;
    fn arguments_names_as_string(&self, contents: &str) -> impl Iterator<Item = Option<String>>;

    fn node_as_str<'a>(&self, source: &'a str) -> anyhow::Result<&'a str>;
    fn node_to_string(&self, source: &str) -> anyhow::Result<String>;
}

impl<'tree> NodeExt for Node<'tree> {
    fn dump(&self, source: &str) -> String {
        let mut output = "\n".to_string();
        _dump_impl(&mut self.walk(), source, "", &mut output);
        output
    }

    fn find_parent(&self, callback: impl Fn(&Self) -> bool) -> Option<Self> {
        let mut node = *self;
        loop {
            if callback(&node) {
                return Some(node);
            }

            node = node.parent()?
        }
    }

    fn find_smallest_spanning_node(&self, point: Point) -> Option<Self> {
        _find_smallest_container(self, point)
    }

    fn find_closest_node_to_point(&self, point: Point) -> Option<Self> {
        match _find_smallest_container(self, point) {
            Some(node) => _find_closest_child(&node, point),
            None => None,
        }
    }

    fn prev_leaf(&self) -> Option<Self> {
        let mut node = *self;
        while node.prev_sibling().is_none() {
            node = node.parent()?
        }

        node = node.prev_sibling().unwrap();

        loop {
            let count = node.child_count();
            if count == 0 {
                break;
            }

            node = node.child(count - 1).unwrap();
        }

        Some(node)
    }

    fn next_leaf(&self) -> Option<Self> {
        let mut node = *self;
        while node.next_sibling().is_none() {
            node = node.parent()?
        }

        node = node.next_sibling().unwrap();

        loop {
            if let Some(child) = node.child(0) {
                node = child;
                continue;
            }
            break;
        }

        Some(node)
    }

    fn fwd_leaf_iter(&self) -> FwdLeafIterator<'_> {
        FwdLeafIterator { node: *self }
    }

    fn bwd_leaf_iter(&self) -> BwdLeafIterator<'_> {
        BwdLeafIterator { node: *self }
    }

    fn ancestors(&self) -> impl Iterator<Item = Node<'tree>> {
        std::iter::successors(Some(*self), |p| p.parent())
    }

    fn next_siblings(&self) -> impl Iterator<Item = Node<'tree>> {
        let mut cursor = self.walk();

        std::iter::from_fn(move || {
            if cursor.goto_next_sibling() {
                Some(cursor.node())
            } else {
                None
            }
        })
    }

    fn children_of(node: Node<'tree>) -> impl Iterator<Item = Node<'tree>> {
        let mut cursor = node.walk();
        let mut done = !cursor.goto_first_child();

        std::iter::from_fn(move || {
            if done {
                None
            } else {
                let item = Some(cursor.node());
                done = !cursor.goto_next_sibling();
                item
            }
        })
    }

    fn arguments(&self) -> impl Iterator<Item = (Option<Node<'tree>>, Option<Node<'tree>>)> {
        self.child_by_field_name("arguments")
            .into_iter()
            .flat_map(Self::children_of)
            .filter_map(|node| {
                if node.kind() != "argument" {
                    return None;
                }

                let name = node.child_by_field_name("name");
                let value = node.child_by_field_name("value");

                Some((name, value))
            })
    }

    fn arguments_names(&self) -> impl Iterator<Item = Option<Node<'tree>>> {
        self.arguments().map(|(name, _value)| name)
    }

    fn arguments_names_as_string(&self, contents: &str) -> impl Iterator<Item = Option<String>> {
        self.arguments_names().map(move |maybe_node| {
            maybe_node.and_then(|node| match node.node_as_str(contents) {
                Err(err) => {
                    tracing::error!("Can't convert argument name to text: {err:?}");
                    None
                },
                Ok(text) => Some(text.to_string()),
            })
        })
    }

    fn node_as_str<'a>(&self, source: &'a str) -> anyhow::Result<&'a str> {
        self.utf8_text(source.as_bytes()).anyhow()
    }

    fn node_to_string(&self, source: &str) -> anyhow::Result<String> {
        self.node_as_str(source)
            .map(|s| s.to_string())
            .map_err(|e| anyhow!(e))
    }

    fn arguments_values(&self) -> impl Iterator<Item = Option<Node<'tree>>> {
        self.arguments().map(|(_name, value)| value)
    }
}

fn _find_smallest_container<'a>(node: &Node<'a>, point: Point) -> Option<Node<'a>> {
    let mut cursor = node.walk();
    let children = node.children(&mut cursor);

    for child in children {
        if _range_contains_point(child.range(), point) {
            return _find_smallest_container(&child, point);
        }
    }

    if _range_contains_point(node.range(), point) {
        Some(*node)
    } else {
        None
    }
}

fn _range_contains_point(range: Range, point: Point) -> bool {
    all!(
        range.start_point.is_before_or_equal(point),
        range.end_point.is_after_or_equal(point)
    )
}

fn _find_closest_child<'a>(node: &Node<'a>, point: Point) -> Option<Node<'a>> {
    let mut cursor = node.walk();
    let children = node.children(&mut cursor);
    let children: Vec<Node> = children.collect();

    for child in children.into_iter().rev() {
        if child.range().start_point.is_before_or_equal(point) {
            return _find_closest_child(&child, point);
        }
    }

    if node.range().start_point.is_before_or_equal(point) {
        Some(*node)
    } else {
        None
    }
}
