//! Plan result cache (M1.3 task 1.3.1, docs/architecture/05 §4.3).
//!
//! Keyed by `(datasetRevision, planHash)` exactly as the contract says, so a data change or a
//! field override invalidates by *missing* rather than by an explicit sweep that could be
//! forgotten. [`ResultCache::retain_revision`] is still offered so a long-lived session does not
//! accumulate pages for revisions it can never ask for again.
//!
//! Lookup is a `BTreeMap`; recency is a `Vec` updated move-to-front, which is O(capacity) per
//! operation. That is a deliberate trade: capacity is small (32 pages by default, a few hundred
//! KB), the constant factor beats a HashMap plus an intrusive list at that size, and there is no
//! unsafe code and no new dependency to audit. If the capacity ever needs to grow past a few
//! hundred, replace the structure — do not raise the constant.

use std::collections::BTreeMap;

/// Default number of cached results. Pages are at most 1024 rows, so this bounds memory to a
/// few MB even for wide tables.
pub const DEFAULT_CAPACITY: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CacheKey {
    pub revision: u64,
    pub plan_hash: u64,
}

impl CacheKey {
    pub fn new(revision: u64, plan_hash: u64) -> CacheKey {
        CacheKey {
            revision,
            plan_hash,
        }
    }
}

/// FNV-1a over the plan's canonical JSON. Not a cryptographic hash and not pretending to be:
/// the key also carries the revision, and a collision would return a wrong page, so the
/// canonical form matters more than the mixing. `serde_json` maps are `BTreeMap` (the
/// `preserve_order` feature is off workspace-wide), so key order is stable across runs.
pub fn hash_json(value: &serde_json::Value) -> u64 {
    let text = serde_json::to_string(value).unwrap_or_default();
    let mut hash: u64 = 0xCBF2_9CE4_8422_2325;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01B3);
    }
    hash
}

/// Hit/miss counters, so a test can prove the cache is actually being used rather than merely
/// present, and so a future perf report can say what the hit rate was.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CacheStats {
    pub hits: u64,
    pub misses: u64,
    pub evictions: u64,
}

#[derive(Debug)]
pub struct ResultCache<V> {
    capacity: usize,
    /// Most recently used first.
    entries: BTreeMap<CacheKey, V>,
    order: Vec<CacheKey>,
    stats: CacheStats,
}

impl<V> Default for ResultCache<V> {
    fn default() -> Self {
        ResultCache::new(DEFAULT_CAPACITY)
    }
}

impl<V> ResultCache<V> {
    pub fn new(capacity: usize) -> ResultCache<V> {
        ResultCache {
            capacity: capacity.max(1),
            entries: BTreeMap::new(),
            order: Vec::new(),
            stats: CacheStats::default(),
        }
    }

    pub fn stats(&self) -> CacheStats {
        self.stats
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn get(&mut self, key: CacheKey) -> Option<&V> {
        if !self.entries.contains_key(&key) {
            self.stats.misses += 1;
            return None;
        }
        self.stats.hits += 1;
        self.order.retain(|k| *k != key);
        self.order.insert(0, key);
        self.entries.get(&key)
    }

    pub fn insert(&mut self, key: CacheKey, value: V) {
        if self.entries.insert(key, value).is_none() {
            self.order.retain(|k| *k != key);
            self.order.insert(0, key);
        }
        while self.order.len() > self.capacity {
            if let Some(oldest) = self.order.pop() {
                self.entries.remove(&oldest);
                self.stats.evictions += 1;
            }
        }
    }

    /// Drop everything that is not `revision`. A new revision already misses; this reclaims the
    /// memory instead of waiting for eviction pressure.
    pub fn retain_revision(&mut self, revision: u64) {
        self.order.retain(|k| k.revision == revision);
        self.entries.retain(|k, _| k.revision == revision);
    }

    pub fn clear(&mut self) {
        self.entries.clear();
        self.order.clear();
    }
}
