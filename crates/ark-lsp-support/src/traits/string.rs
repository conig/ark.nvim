//
// string.rs
//
// Copyright (C) 2022 Posit Software, PBC. All rights reserved.
//
//

fn _fuzzy_matches(lhs: &str, rhs: &str) -> bool {
    let mut it = rhs.chars();
    let mut rch = match it.next() {
        Some(rhs) => rhs,
        None => return true,
    };

    for lch in lhs.chars() {
        if lch.eq_ignore_ascii_case(&rch) {
            rch = match it.next() {
                Some(rch) => rch,
                None => return true,
            }
        }
    }

    false
}

pub trait StringExt {
    fn fuzzy_matches(&self, rhs: impl AsRef<str>) -> bool;
}

impl StringExt for &str {
    fn fuzzy_matches(&self, rhs: impl AsRef<str>) -> bool {
        _fuzzy_matches(self, rhs.as_ref())
    }
}

impl StringExt for String {
    fn fuzzy_matches(&self, rhs: impl AsRef<str>) -> bool {
        _fuzzy_matches(self.as_ref(), rhs.as_ref())
    }
}
