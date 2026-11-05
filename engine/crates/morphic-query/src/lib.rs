//! # morphic-query
//!
//! Deterministic query execution over columnar tables (docs/architecture/05 §4).
//!
//! **Phase 0 status:** the plan grammar types and a trivial `count` are defined so the
//! crate boundary and FFI contract exist. Full filter/sort/group/aggregate execution,
//! paging, budgets, and the LRU cache land in M1.3. Nothing here is presented as complete.

use morphic_model::Table;
use serde::{Deserialize, Serialize};

/// A validated, deterministic query plan. The grammar is closed — never AI-executed.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    #[serde(default)]
    pub search: Option<String>,
    #[serde(default)]
    pub offset: usize,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    256
}

/// Phase 0: total row count. Real operators arrive in M1.3.
pub fn count(table: &Table) -> usize {
    table.row_count
}

#[cfg(test)]
mod tests {
    use super::*;
    use morphic_model::Table;

    #[test]
    fn count_returns_row_count() {
        let t = Table { columns: vec![], row_count: 42 };
        assert_eq!(count(&t), 42);
    }

    #[test]
    fn plan_default_limit() {
        let p = Plan::default();
        assert_eq!(p.limit, 0); // Default derive; serde default applies on deserialize
        let p2: Plan = serde_json::from_str("{}").unwrap();
        assert_eq!(p2.limit, 256);
    }
}
