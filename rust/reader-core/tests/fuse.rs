use reader_core::fuse::{reciprocal_rank_fusion, RankedItem};

fn item(path: &str, score: f64) -> RankedItem {
    RankedItem {
        path: path.to_string(),
        score,
    }
}

#[test]
fn rrf_basic_single_list() {
    let list = vec![item("a", 10.0), item("b", 5.0), item("c", 1.0)];
    let fused = reciprocal_rank_fusion(vec![list], &[1.0], 60);
    assert_eq!(fused.len(), 3);
    assert_eq!(fused[0].path, "a");
    assert!(fused[0].score > fused[1].score);
}

#[test]
fn rrf_two_lists_dedup_by_path() {
    let lex = vec![item("a", 10.0), item("b", 5.0)];
    let vec = vec![item("b", 0.6), item("c", 0.5)];
    let fused = reciprocal_rank_fusion(vec![lex, vec], &[1.0, 1.0], 60);
    assert_eq!(fused.len(), 3);
    let b = fused.iter().find(|f| f.path == "b").unwrap();
    let a = fused.iter().find(|f| f.path == "a").unwrap();
    // b appears in both lists, so its RRF score must beat a (which is in only one)
    assert!(b.score > a.score, "b={} a={}", b.score, a.score);
}

#[test]
fn rrf_top_rank_bonus_applied() {
    let only = vec![item("a", 1.0), item("b", 1.0), item("c", 1.0)];
    let fused = reciprocal_rank_fusion(vec![only], &[1.0], 60);
    // top-rank gets +0.05, rank-2 gets +0.02, rank-3 gets 0
    let a = fused.iter().find(|f| f.path == "a").unwrap().score;
    let b = fused.iter().find(|f| f.path == "b").unwrap().score;
    let c = fused.iter().find(|f| f.path == "c").unwrap().score;
    assert!((a - b).abs() < 0.05 + 0.001, "a-b distance includes top-rank bonus");
    assert!(b > c);
}

#[test]
fn rrf_empty_list_does_not_crash() {
    let empty: Vec<RankedItem> = vec![];
    let other = vec![item("a", 1.0)];
    let fused = reciprocal_rank_fusion(vec![empty, other], &[1.0, 1.0], 60);
    assert_eq!(fused.len(), 1);
    assert_eq!(fused[0].path, "a");
}
