//! `.morphic` workspace bundles (M1.5 task 1.5.6).
//!
//! The design sketch in doc 06 called for a ZIP. This crate has no ZIP dependency, and adding
//! one for three small files would widen the supply-chain surface for no user-visible gain. The
//! shipped format is instead a single UTF-8 JSON envelope: a manifest, the authoritative
//! `WorkspaceDoc`, and the referenced source bytes hex-encoded so the whole bundle stays valid
//! JSON and trivially diffable. The `.morphic` extension is the contract; the bytes are honest
//! about their format rather than pretending to be a ZIP.

use serde::{Deserialize, Serialize};

use morphic_schema::WorkspaceDoc;

use crate::{content_hash, StoreError};

pub const BUNDLE_FORMAT: &str = "morphic/workspace-bundle/1";

/// Metadata about the exported workspace. Kept separate from the envelope so both the export
/// response and the file itself carry exactly the same identity fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleManifest {
    pub format: String,
    pub schema_version: String,
    pub workspace_id: String,
    pub title: String,
    pub exported_at: String,
    pub dataset_count: usize,
}

/// One content-addressed source. `contentHex` is the exact byte stream; `hash` is its SHA-256
/// and is verified on import before anything is written.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleDataset {
    pub hash: String,
    pub source_name: String,
    pub content_hex: String,
    pub bytes: usize,
}

/// The complete `.morphic` file contents.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleEnvelope {
    pub manifest: BundleManifest,
    pub workspace: WorkspaceDoc,
    pub datasets: Vec<BundleDataset>,
}

/// What `FileStore::export_bundle` hands back to the engine/FFI layer.
#[derive(Debug, Clone)]
pub struct BundleExport {
    pub json: String,
    pub manifest: BundleManifest,
    pub bytes: usize,
}

/// What `FileStore::import_bundle` returns after persisting the bundle.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleImportOutcome {
    pub doc: WorkspaceDoc,
    pub source_title: String,
    pub dataset_count: usize,
}

/// One source whose declared hash and byte count have both been verified.
#[derive(Debug, Clone)]
pub struct BundleSource {
    pub hash: String,
    pub bytes: Vec<u8>,
}

/// The verified contents of an envelope, before a fresh workspace id is assigned. A named
/// struct keeps `decode_bundle`'s signature legible (and satisfies clippy's type-complexity
/// lint) while making the verification boundary explicit.
#[derive(Debug, Clone)]
pub struct DecodedBundle {
    pub manifest: BundleManifest,
    pub workspace: WorkspaceDoc,
    pub datasets: Vec<BundleSource>,
}

/// Lowercase hex; two characters per byte. No external codec dependency.
pub fn hex_encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(DIGITS[(b >> 4) as usize] as char);
        out.push(DIGITS[(b & 0x0f) as usize] as char);
    }
    out
}

fn hex_value(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

pub fn hex_decode(text: &str) -> Result<Vec<u8>, StoreError> {
    let raw = text.as_bytes();
    if raw.len() % 2 != 0 {
        return Err(StoreError::Bundle("odd-length hex source".into()));
    }
    let mut out = Vec::with_capacity(raw.len() / 2);
    for pair in raw.chunks(2) {
        let hi =
            hex_value(pair[0]).ok_or_else(|| StoreError::Bundle("invalid hex source".into()))?;
        let lo =
            hex_value(pair[1]).ok_or_else(|| StoreError::Bundle("invalid hex source".into()))?;
        out.push((hi << 4) | lo);
    }
    Ok(out)
}

/// Serialize a workspace and its datasets into a `.morphic` JSON envelope.
pub fn encode_bundle(
    doc: &WorkspaceDoc,
    datasets: &[(String, Vec<u8>)],
    exported_at: &str,
) -> Result<BundleExport, StoreError> {
    let encoded = datasets
        .iter()
        .map(|(hash, bytes)| BundleDataset {
            hash: hash.clone(),
            source_name: "source.csv".to_string(),
            content_hex: hex_encode(bytes),
            bytes: bytes.len(),
        })
        .collect::<Vec<_>>();
    let manifest = BundleManifest {
        format: BUNDLE_FORMAT.to_string(),
        schema_version: doc.schema_version.clone(),
        workspace_id: doc.workspace.id.clone(),
        title: doc.workspace.title.clone(),
        exported_at: exported_at.to_string(),
        dataset_count: encoded.len(),
    };
    let envelope = BundleEnvelope {
        manifest: manifest.clone(),
        workspace: doc.clone(),
        datasets: encoded,
    };
    let json = serde_json::to_string_pretty(&envelope)?;
    let bytes = json.len();
    Ok(BundleExport {
        json,
        manifest,
        bytes,
    })
}

/// Parse and verify a `.morphic` envelope. Hash verification happens here so a caller cannot
/// accidentally persist tampered source bytes under a trusted hash.
pub fn decode_bundle(bytes: &[u8]) -> Result<DecodedBundle, StoreError> {
    let envelope: BundleEnvelope = serde_json::from_slice(bytes)
        .map_err(|e| StoreError::Bundle(format!("not a .morphic bundle: {e}")))?;
    let manifest = envelope.manifest;
    if manifest.format != BUNDLE_FORMAT {
        return Err(StoreError::Bundle(format!(
            "unsupported bundle format '{}'",
            manifest.format
        )));
    }
    if manifest.workspace_id != envelope.workspace.workspace.id {
        return Err(StoreError::Bundle(
            "manifest workspace id does not match workspace.json".into(),
        ));
    }
    if manifest.schema_version != envelope.workspace.schema_version {
        return Err(StoreError::Bundle(
            "manifest schemaVersion does not match workspace.json".into(),
        ));
    }
    if manifest.dataset_count != envelope.datasets.len() {
        return Err(StoreError::Bundle(
            "manifest dataset count does not match datasets".into(),
        ));
    }
    let mut datasets = Vec::with_capacity(envelope.datasets.len());
    for ds in envelope.datasets {
        let decoded = hex_decode(&ds.content_hex)?;
        if decoded.len() != ds.bytes {
            return Err(StoreError::Bundle(format!(
                "dataset '{}' declares {} bytes but carries {}",
                ds.hash,
                ds.bytes,
                decoded.len()
            )));
        }
        if content_hash(&decoded) != ds.hash {
            return Err(StoreError::Bundle(format!(
                "dataset '{}' does not match its content hash",
                ds.hash
            )));
        }
        datasets.push(BundleSource {
            hash: ds.hash,
            bytes: decoded,
        });
    }
    Ok(DecodedBundle {
        manifest,
        workspace: envelope.workspace,
        datasets,
    })
}
