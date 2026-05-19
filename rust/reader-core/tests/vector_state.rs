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
