use reader_core::vector::{ModelHandle, ModelState};
use std::time::Duration;

#[tokio::test]
async fn starts_uninitialized() {
    let handle = ModelHandle::new();
    assert!(matches!(handle.snapshot().await, ModelState::Uninitialized));
}

#[tokio::test]
async fn disabled_state_is_sticky() {
    let handle = ModelHandle::new();
    handle.disable("sqlite-vec missing").await;
    let s = handle.snapshot().await;
    assert!(matches!(s, ModelState::Disabled(_)));

    // ensure_loaded should never transition out of Disabled
    let result = handle.ensure_loaded_for_test_fail().await;
    assert!(result.is_err());
    assert!(matches!(handle.snapshot().await, ModelState::Disabled(_)));
}

#[test]
fn vec_search_filter_pushdown_returns_typed_only() {
    use rusqlite::Connection;
    reader_core::init_sqlite_vec();
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(
        "CREATE TABLE entries (path TEXT PRIMARY KEY, type TEXT, rating_score REAL DEFAULT 0);
         CREATE VIRTUAL TABLE entry_vectors USING vec0(path TEXT PRIMARY KEY, embedding float[4] distance_metric=cosine);",
    )
    .unwrap();
    let bytes = |v: [f32; 4]| -> Vec<u8> { v.iter().flat_map(|f| f.to_le_bytes()).collect() };
    for (path, ty, v) in [
        ("a.md", "paper-analysis", [1.0_f32, 0.0, 0.0, 0.0]),
        ("b.md", "book-overview", [0.9, 0.1, 0.0, 0.0]),
        ("c.md", "paper-analysis", [0.0, 1.0, 0.0, 0.0]),
    ] {
        conn.execute(
            "INSERT INTO entries(path, type, rating_score) VALUES (?,?,1.0)",
            rusqlite::params![path, ty],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO entry_vectors(path, embedding) VALUES (?, ?)",
            rusqlite::params![path, bytes(v)],
        )
        .unwrap();
    }
    let q = [1.0_f32, 0.0, 0.0, 0.0];
    let hits =
        reader_core::vector::vec_search(&conn, &q, 5, Some("paper-analysis"), None).unwrap();
    let paths: Vec<_> = hits.iter().map(|h| h.path.as_str()).collect();
    assert!(paths.contains(&"a.md"));
    assert!(!paths.contains(&"b.md"), "type filter must exclude book-overview");
}

#[tokio::test]
async fn failed_state_backs_off() {
    let handle = ModelHandle::new();
    handle
        .force_failed("simulated", Duration::from_millis(50))
        .await;
    // immediately retry → still Failed
    assert!(handle.ensure_loaded_for_test_fail().await.is_err());
    let s = handle.snapshot().await;
    assert!(matches!(s, ModelState::Failed { .. }));
}
