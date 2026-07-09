#[path = "../../build/product_metadata.rs"]
mod product_metadata;

fn main() {
    product_metadata::emit();
}
