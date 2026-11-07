//! Wall-clock budget (docs/architecture/05 §4.3: check every 64k rows, 2 s default).
//!
//! The check is cooperative and sits at row checkpoints, not inside `sort_by`: Rust's sort is
//! opaque, so a deadline cannot interrupt it. That is a real limit and is stated rather than
//! implied — the scan and the group pass are interruptible, the sort of an already-selected
//! vector is not. Selection is what scales with hostile input, and it is checked.

use std::time::{Duration, Instant};

use crate::QueryError;

pub const DEFAULT_BUDGET_MS: u64 = 2000;
/// Rows between deadline checks. Small enough to stay responsive, large enough that the clock
/// read is not itself the cost.
pub const CHECK_ROWS: usize = 65_536;

#[derive(Debug, Clone)]
pub(crate) struct Deadline {
    start: Instant,
    budget: Duration,
}

impl Deadline {
    pub(crate) fn new(budget_ms: Option<u64>) -> Deadline {
        Deadline {
            start: Instant::now(),
            budget: Duration::from_millis(budget_ms.unwrap_or(DEFAULT_BUDGET_MS)),
        }
    }

    /// A zero budget is always expired, which makes the limit testable without a sleep.
    pub(crate) fn check(&self, stage: &str) -> Result<(), QueryError> {
        let elapsed = self.start.elapsed();
        if self.budget.is_zero() || elapsed > self.budget {
            return Err(QueryError::ResourceLimit(format!(
                "query exceeded its {} ms budget during {stage} ({} ms elapsed)",
                self.budget.as_millis(),
                elapsed.as_millis()
            )));
        }
        Ok(())
    }
}
