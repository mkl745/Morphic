//! Byte → text decoding with an explicit, reported encoding decision.
//!
//! Policy (docs/architecture/05 §1, M1.1):
//! * a UTF-8 / UTF-16 BOM is honoured and stripped;
//! * otherwise UTF-8 is attempted **strictly** — we never silently replace bad bytes;
//! * if strict UTF-8 fails we fall back to Latin-1 (a total, lossless byte→char mapping)
//!   and record a warning so the user knows the file was not UTF-8.
//!
//! M1.2 1.2.3 added the edge cases that silently corrupt real files: mixed/invalid UTF-8 is
//! counted and located rather than just labelled, mixed and CR-only line endings are
//! reported, and a probable UTF-16 file *without* a BOM is flagged instead of being read as
//! NUL-riddled text.
//!
//! Deliberate debt, still open after 1.2.3: statistical charset detection (`chardetng`).
//! Latin-1 is the architecturally-compatible smaller version — it never panics and never
//! loses bytes, but it mis-renders windows-1252 punctuation in 0x80..0x9F. The warning now
//! says exactly how many byte sequences were affected and where the first one is, so the
//! user can judge the damage instead of guessing. Reported, not hidden.

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
            let nuls = body.iter().filter(|b| **b == 0).count();
            if nuls > 0 {
                // A quarter or more NULs is not text with the odd stray byte; it is almost
                // always UTF-16/32 saved without a BOM. Guessing the endianness would be
                // worse than saying so.
                if nuls * 4 >= body.len() {
                    warnings.push(format!(
                        "{nuls} of {} bytes are NUL. This looks like UTF-16 or UTF-32 saved \
                         without a byte-order mark; it was read as UTF-8, so the text will \
                         be wrong. Re-save with a BOM or as UTF-8.",
                        body.len()
                    ));
                } else {
                    warnings.push("Input contains NUL bytes; they were kept as data.".into());
                }
            }
            let mut d = Decoded {
                text: s.to_string(),
                encoding: "utf-8".into(),
                warnings,
            };
            note_line_endings(&d.text, &mut d.warnings);
            d
        }
        Err(_) => {
            // Latin-1: every byte maps to exactly one char, so this is total.
            let text: String = body.iter().map(|&b| b as char).collect();
            let (count, first) = utf8_issues(body);
            let where_at = match first {
                Some(offset) => format!(" The first is at byte {offset}."),
                None => String::new(),
            };
            warnings.push(format!(
                "Input is not valid UTF-8: {count} byte sequence(s) could not be decoded, so \
                 the file was read as Latin-1.{where_at} Accents are usually correct, but \
                 windows-1252 punctuation (0x80-0x9F) can render as control characters. \
                 Re-save as UTF-8 if the text looks wrong."
            ));
            let mut d = Decoded {
                text,
                encoding: "latin-1 (fallback)".into(),
                warnings,
            };
            note_line_endings(&d.text, &mut d.warnings);
            d
        }
    }
}

/// Count invalid UTF-8 sequences and locate the first. Bounded work: one pass, no allocation.
fn utf8_issues(mut body: &[u8]) -> (usize, Option<usize>) {
    let mut count = 0usize;
    let mut first = None;
    let mut offset = 0usize;
    while let Err(e) = std::str::from_utf8(body) {
        let valid = e.valid_up_to();
        if first.is_none() {
            first = Some(offset + valid);
        }
        count += 1;
        // `None` means the input ended mid-sequence: everything remaining is the one issue.
        let skip = e.error_len().unwrap_or(body.len() - valid);
        let advance = valid + skip;
        if advance == 0 {
            break;
        }
        offset += advance;
        body = &body[advance..];
    }
    (count, first)
}

/// Report line-ending problems the parsers cannot fix for the user.
///
/// `str::lines` and the `csv` crate both handle LF and CRLF, so those are silent. A **lone
/// CR** is not a line separator for either, which would turn a classic-Mac file into one
/// enormous row — that must be said out loud rather than imported as a single line.
fn note_line_endings(text: &str, warnings: &mut Vec<String>) {
    let crlf = text.matches("\r\n").count();
    let lf = text.matches('\n').count();
    let cr = text.matches('\r').count();
    let bare_lf = lf.saturating_sub(crlf);
    let lone_cr = cr.saturating_sub(crlf);
    if crlf > 0 && bare_lf > 0 {
        warnings.push(format!(
            "Mixed line endings: {crlf} CRLF and {bare_lf} bare LF. Both were handled, but \
             the file was probably written by more than one tool."
        ));
    }
    if lone_cr > 0 {
        warnings.push(format!(
            "{lone_cr} lone carriage return(s) found. Lines are split on LF/CRLF only, so \
             CR-only text reads as a single line; re-save with LF or CRLF line endings."
        ));
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

    // ---------------------------------------------- M1.2 1.2.3 encoding edges

    fn has(d: &Decoded, needle: &str) -> bool {
        d.warnings.iter().any(|w| w.contains(needle))
    }

    #[test]
    fn invalid_utf8_reports_how_many_and_where() {
        let d = decode(&[b'a', b',', 0xE9, b'\n']);
        assert!(has(&d, "1 byte sequence(s)"), "{:?}", d.warnings);
        assert!(has(&d, "first is at byte 2"), "{:?}", d.warnings);
    }

    #[test]
    fn several_invalid_sequences_are_all_counted() {
        let d = decode(&[b'a', 0xE9, b'b', 0xFC, b'c', 0x80]);
        assert!(has(&d, "3 byte sequence(s)"), "{:?}", d.warnings);
        assert!(has(&d, "first is at byte 1"), "{:?}", d.warnings);
    }

    #[test]
    fn a_multibyte_sequence_cut_off_at_eof_is_counted_once() {
        // error_len() is None here: the input ends mid-sequence.
        let d = decode(&[b'a', 0xC3]);
        assert_eq!(d.encoding, "latin-1 (fallback)");
        assert!(has(&d, "1 byte sequence(s)"), "{:?}", d.warnings);
    }

    #[test]
    fn crlf_alone_is_not_a_warning() {
        let d = decode(b"a,b\r\n1,2\r\n");
        assert!(d.warnings.is_empty(), "{:?}", d.warnings);
    }

    #[test]
    fn mixed_line_endings_are_reported() {
        let d = decode(b"a,b\r\n1,2\n3,4\r\n");
        assert!(has(&d, "Mixed line endings"), "{:?}", d.warnings);
        assert!(has(&d, "2 CRLF and 1 bare LF"), "{:?}", d.warnings);
    }

    #[test]
    fn a_cr_only_file_is_flagged_because_it_reads_as_one_line() {
        let d = decode(b"a,b\r1,2\r3,4\r");
        assert!(has(&d, "lone carriage return"), "{:?}", d.warnings);
        assert!(has(&d, "single line"), "{:?}", d.warnings);
    }

    #[test]
    fn utf16_without_a_bom_is_flagged_not_silently_mangled() {
        // ASCII encoded as UTF-16LE with no BOM: every other byte is NUL.
        let mut bytes = Vec::new();
        for u in "a,b\n1,2\n".encode_utf16() {
            bytes.extend_from_slice(&u.to_le_bytes());
        }
        let d = decode(&bytes);
        assert!(has(&d, "without a byte-order mark"), "{:?}", d.warnings);
    }

    #[test]
    fn a_couple_of_stray_nuls_are_not_called_utf16() {
        let d = decode(b"some perfectly ordinary text with one \0 inside\n");
        assert!(has(&d, "kept as data"), "{:?}", d.warnings);
        assert!(!has(&d, "byte-order mark"), "{:?}", d.warnings);
    }

    #[test]
    fn mixed_encoding_never_panics_and_never_loses_bytes() {
        // Valid UTF-8, then Latin-1, then valid UTF-8 again: the classic mixed file.
        let mut bytes = "name\n".as_bytes().to_vec();
        bytes.push(0xE9); // latin-1 e-acute
        bytes.extend_from_slice("cafÃ©\n".as_bytes());
        let d = decode(&bytes);
        assert_eq!(d.encoding, "latin-1 (fallback)");
        // Latin-1 is a total byte->char mapping: one char per byte, nothing dropped.
        assert_eq!(d.text.chars().count(), bytes.len());
    }
}
