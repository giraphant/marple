//! Reciprocal-Rank Fusion for combining multiple ranked retrieval lists.
//!
//! Standard formula: each path's RRF score = Σ_lists w_i / (k + rank_i + 1).
//! A small top-rank bonus (+0.05 if any list ranks it #1, +0.02 if any list
//! ranks it #2 or #3) helps stable inter-list winners surface.

use std::collections::HashMap;

#[derive(Clone, Debug)]
pub struct RankedItem {
    pub path: String,
    pub score: f64,
}

pub fn reciprocal_rank_fusion(
    lists: Vec<Vec<RankedItem>>,
    weights: &[f64],
    k: usize,
) -> Vec<RankedItem> {
    let mut agg: HashMap<String, (f64, usize)> = HashMap::new();

    for (li, list) in lists.iter().enumerate() {
        let w = weights.get(li).copied().unwrap_or(1.0);
        for (rank, item) in list.iter().enumerate() {
            let contribution = w / ((k + rank + 1) as f64);
            let entry = agg
                .entry(item.path.clone())
                .or_insert((0.0, usize::MAX));
            entry.0 += contribution;
            if rank < entry.1 {
                entry.1 = rank;
            }
        }
    }

    let mut out: Vec<RankedItem> = agg
        .into_iter()
        .map(|(path, (mut score, top_rank))| {
            // qmd-style top-rank bonus
            if top_rank == 0 {
                score += 0.05;
            } else if top_rank <= 2 {
                score += 0.02;
            }
            RankedItem { path, score }
        })
        .collect();

    out.sort_by(|a, b| b.score.total_cmp(&a.score));
    out
}
