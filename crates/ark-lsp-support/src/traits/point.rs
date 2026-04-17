//
// point.rs
//
// Copyright (C) 2022 Posit Software, PBC. All rights reserved.
//
//

use tree_sitter::Point;

fn compare(lhs: Point, rhs: Point) -> i32 {
    if lhs.row < rhs.row {
        -1
    } else if lhs.row > rhs.row {
        1
    } else if lhs.column < rhs.column {
        -1
    } else if lhs.column > rhs.column {
        1
    } else {
        0
    }
}

#[expect(clippy::wrong_self_convention)]
pub trait PointExt {
    fn is_before(self, other: Point) -> bool;
    fn is_before_or_equal(self, other: Point) -> bool;
    fn is_equal(self, other: Point) -> bool;
    fn is_after_or_equal(self, other: Point) -> bool;
    fn is_after(self, other: Point) -> bool;
}

impl PointExt for Point {
    fn is_before(self, other: Point) -> bool {
        compare(self, other) < 0
    }

    fn is_before_or_equal(self, other: Point) -> bool {
        compare(self, other) <= 0
    }

    fn is_equal(self, other: Point) -> bool {
        compare(self, other) == 0
    }

    fn is_after_or_equal(self, other: Point) -> bool {
        compare(self, other) >= 0
    }

    fn is_after(self, other: Point) -> bool {
        compare(self, other) > 0
    }
}
