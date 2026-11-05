//! Byte → text decoding with an explicit, reported encoding decision.
//!
//! Policy (docs/architecture/05 §1, M1.1):
//! * a UTF-8 / UTF-16 BOM is honoured and stripped;
//! * otherwise UTF-8 is attempted **strictly** — we never silently replace bad bytes;
//! * if strict UTF-8 fails we fall back to Latin-1 (a total, lossless byte→char mapping)
//!   and record a warning so the user knows the file was not UTF-8.
//!
//! Deliberate debt: statistical charset detection (`chardetng`) is M1.2. Latin-1 is the
//! architecturally-compatible smaller version — it never panics and never loses bytes,
//! but it will mis-render windows-1252 punctuation in 0x80..0x9F. Reported, not hidden.

/// The outcome of decoding an input file.
#[derive(Debug, Clone)]
pub struct Decoded {
    pub text: String,
    /// Human-readable encoding label for `ImportReport`.
    pub encoding: String,
    pub warnings: Vec<String>,
}

const UTF8_BOM: &[u8] = &[0xEF, 0xBB, 0xBF];
const UTF16LE_BOM: &[u8] = &[0xFF, 0xFE];
const UTF16BE_BOM: &[u8] = &[0xFE, 0xFF];

/// Decode `bytes` to text, reporting the encoding used and any concerns.
pub fn decode(bytes: &[u8]) -> Decoded {
    let mut warnings = Vec::new();

    // UTF-16 is only honoured when explicitly signalled by a BOM.
    if bytes.starts_with(UTF16LE_BOM) {
        let units: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        if bytes.len() % 2 != 0 {
            warnings.push("UTF-16LE input had a trailing odd byte; it was ignored.".into());
        }
        let text = String::from_utf16_lossy(&units);
        return Decoded {
            text,
            encoding: "utf-16le".into(),
            warnings,
        };
    }
    if bytes.starts_with(UTF16BE_BOM) {
        let units: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|c| u16::from_be_bytes([c[0], c[1]]))
            .collect();
        if bytes.len() % 2 != 0 {
            warnings.push("UTF-16BE input had a trailing odd byte; it was ignored.".into());
        }
        let text = String::from_utf16_lossy(&units);
        return Decoded {
            text,
            encoding: "utf-16be".into(),
            warnings,
        };
    }

    let body = if bytes.starts_with(UTF8_BOM) {
        warnings.push("A UTF-8 BOM was present and was removed.".into());
        &bytes[3..]
    } else {
        bytes
    };

    match std::str::from_utf8(body) {
        Ok(s) => {
            if s.contains('\0') {
                warnings.push("Input contains NUL bytes; they were kept as data.".into());
            }
            Decoded {
                text: s.to_string(),
                encoding: "utf-8".into(),
                warnings,
            }
        }
        Err(_) => {
            // Latin-1: every byte maps to exactly one char, so this is total.
            let text: String = body.iter().map(|&b| b as char).collect();
            warnings.push(
                "Input is not valid UTF-8; decoded as Latin-1. Accents may be correct, \
                 but windows-1252 punctuation can render incorrectly (detection lands in M1.2)."
                    .into(),
            );
            Decoded {
                text,
                encoding: "latin-1 (fallback)".into(),
                warnings,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_utf8_is_clean() {
        let d = decode("héllo,world\n".as_bytes());
        assert_eq!(d.encoding, "utf-8");
        assert!(d.warnings.is_empty());
        assert!(d.text.starts_with("héllo"));
    }

    #[test]
    fn utf8_bom_is_stripped_and_reported() {
        let mut bytes = UTF8_BOM.to_vec();
        bytes.extend_from_slice(b"a,b\n");
        let d = decode(&bytes);
        assert_eq!(d.text, "a,b\n");
        assert_eq!(d.encoding, "utf-8");
        assert_eq!(d.warnings.len(), 1);
    }

    #[test]
    fn invalid_utf8_falls_back_to_latin1_without_panicking() {
        // 0xE9 is 'é' in Latin-1 but an invalid standalone UTF-8 lead byte.
        let d = decode(&[b'a', b',', 0xE9, b'\n']);
        assert_eq!(d.encoding, "latin-1 (fallback)");
        assert!(d.text.contains('é'));
        assert_eq!(d.warnings.len(), 1);
    }

    #[test]
    fn utf16le_bom_is_decoded() {
        let mut bytes = UTF16LE_BOM.to_vec();
        for u in "a,b\n".encode_utf16() {
            bytes.extend_from_slice(&u.to_le_bytes());
        }
        let d = decode(&bytes);
        assert_eq!(d.encoding, "utf-16le");
        assert_eq!(d.text, "a,b\n");
    }

    #[test]
    fn nul_bytes_are_reported_not_dropped() {
        let d = decode(b"a,b\n\0,z\n");
        assert!(d.text.contains('\0'));
        assert!(d.warnings.iter().any(|w| w.contains("NUL")));
    }
}
