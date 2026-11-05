//! Export the JSON Schema + registry manifest artifacts from the Rust types.
//! Run from the workspace root: `cargo run -p morphic-schema --bin export`.
//! CI regenerates these and fails on drift (docs/engineering/ci-cd.md).

use std::fs;
use std::path::Path;

fn main() {
    let out_dir = Path::new("schemas");
    fs::create_dir_all(out_dir).expect("create schemas dir");

    let schema = morphic_schema::export_json_schema();
    let schema_path = out_dir.join("morphic_ui_schema_v1.json");
    fs::write(
        &schema_path,
        serde_json::to_string_pretty(&schema).expect("serialize schema") + "\n",
    )
    .expect("write schema");

    let manifest = morphic_schema::registry_manifest();
    let manifest_path = out_dir.join("registry_v1.json");
    fs::write(
        &manifest_path,
        serde_json::to_string_pretty(&manifest).expect("serialize manifest") + "\n",
    )
    .expect("write manifest");

    println!("exported {} and {}", schema_path.display(), manifest_path.display());
}
