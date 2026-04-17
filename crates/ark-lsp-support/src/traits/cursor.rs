//
// cursor.rs
//
// Copyright (C) 2022 Posit Software, PBC. All rights reserved.
//
//

use tree_sitter::Node;
use tree_sitter::Point;
use tree_sitter::TreeCursor;

fn _recurse_impl<Callback: FnMut(Node) -> bool>(this: &mut TreeCursor, callback: &mut Callback) {
    if !callback(this.node()) {
        return;
    }

    if this.goto_first_child() {
        _recurse_impl(this, callback);
        while this.goto_next_sibling() {
            _recurse_impl(this, callback);
        }
        this.goto_parent();
    }
}

fn _find_impl<Callback: FnMut(Node) -> bool>(
    this: &mut TreeCursor,
    callback: &mut Callback,
) -> bool {
    if !callback(this.node()) {
        return false;
    }

    if this.goto_first_child() {
        if !_find_impl(this, callback) {
            return false;
        }

        while this.goto_next_sibling() {
            if !_find_impl(this, callback) {
                return false;
            }
        }

        this.goto_parent();
    }

    true
}

pub trait TreeCursorExt {
    fn recurse<Callback: FnMut(Node) -> bool>(&mut self, callback: Callback);

    fn find<Callback: FnMut(Node) -> bool>(&mut self, callback: Callback) -> bool;

    fn find_parent<Callback: FnMut(Node) -> bool>(&mut self, callback: Callback) -> bool;

    /// Move this cursor to the first child of its current node that extends
    /// beyond or touches the given point. Returns `true` if a child node was found,
    /// otherwise returns `false`.
    ///
    /// TODO: In theory we should be using `cursor.goto_first_child_for_point()`,
    /// but it is reported to be broken, and indeed does not work right if I
    /// substitute it in.
    /// https://github.com/tree-sitter/tree-sitter/issues/2012
    ///
    /// This simple reimplementation is based on this Emacs hot patch
    /// https://git.savannah.gnu.org/cgit/emacs.git/commit/?h=emacs-29&id=7c61a304104fe3a35c47d412150d29b93a697c5e
    fn goto_first_child_for_point_patched(&mut self, point: Point) -> bool;
}

impl TreeCursorExt for TreeCursor<'_> {
    fn recurse<Callback: FnMut(Node) -> bool>(&mut self, mut callback: Callback) {
        _recurse_impl(self, &mut callback)
    }

    fn find<Callback: FnMut(Node) -> bool>(&mut self, mut callback: Callback) -> bool {
        _find_impl(self, &mut callback)
    }

    fn find_parent<Callback: FnMut(Node) -> bool>(&mut self, mut callback: Callback) -> bool {
        while self.goto_parent() {
            if callback(self.node()) {
                return true;
            }
        }

        false
    }

    fn goto_first_child_for_point_patched(&mut self, point: Point) -> bool {
        if !self.goto_first_child() {
            return false;
        }

        let mut node = self.node();

        while node.end_position() < point {
            if self.goto_next_sibling() {
                node = self.node();
            } else {
                return false;
            }
        }

        true
    }
}
