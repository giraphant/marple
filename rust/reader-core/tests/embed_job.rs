use reader_core::embed_job::{EmbedJob, EmbedOutcome, EmbedPhase};
use std::sync::Arc;

#[test]
fn starts_idle() {
    let job = EmbedJob::new();
    let s = job.snapshot();
    assert_eq!(s.phase, EmbedPhase::Idle);
    assert_eq!(s.embedded, 0);
    assert_eq!(s.total, 0);
    assert!(s.started_at.is_none());
    assert!(s.completed_at.is_none());
    assert!(s.error.is_none());
}

#[test]
fn try_begin_is_single_flight() {
    let job = EmbedJob::new();
    assert!(job.try_begin(), "first try_begin wins");
    assert_eq!(job.snapshot().phase, EmbedPhase::Running);
    assert!(job.snapshot().started_at.is_some());
    assert!(!job.try_begin(), "second try_begin while running loses");
    assert_eq!(job.snapshot().phase, EmbedPhase::Running);
}

#[test]
fn progress_is_reflected_in_snapshot() {
    let job = EmbedJob::new();
    job.try_begin();
    job.set_total(10);
    job.set_embedded(3);
    job.set_embedded(5);
    let s = job.snapshot();
    assert_eq!(s.total, 10);
    assert_eq!(s.embedded, 5);
}

#[test]
fn finish_ok_marks_done_with_completed_at() {
    let job = EmbedJob::new();
    job.try_begin();
    job.finish_ok();
    let s = job.snapshot();
    assert_eq!(s.phase, EmbedPhase::Done);
    assert!(s.completed_at.is_some());
    assert!(s.error.is_none());
}

#[test]
fn finish_err_marks_failed_with_error() {
    let job = EmbedJob::new();
    job.try_begin();
    job.finish_err("boom");
    let s = job.snapshot();
    assert_eq!(s.phase, EmbedPhase::Failed);
    assert_eq!(s.error.as_deref(), Some("boom"));
}

#[test]
fn can_retry_after_terminal_state() {
    let job = EmbedJob::new();
    job.try_begin();
    job.finish_err("first failure");
    assert_eq!(job.snapshot().phase, EmbedPhase::Failed);

    // A new run is allowed and must reset progress + error.
    assert!(job.try_begin(), "retry after Failed is allowed");
    let s = job.snapshot();
    assert_eq!(s.phase, EmbedPhase::Running);
    assert_eq!(s.embedded, 0);
    assert_eq!(s.total, 0);
    assert!(s.error.is_none());

    job.finish_ok();
    assert_eq!(job.snapshot().phase, EmbedPhase::Done);
    assert!(job.try_begin(), "retry after Done is allowed");
}

#[test]
fn concurrent_try_begin_yields_exactly_one_winner() {
    let job = Arc::new(EmbedJob::new());
    let threads = 16;
    let barrier = Arc::new(std::sync::Barrier::new(threads));
    let mut handles = Vec::new();
    for _ in 0..threads {
        let job = job.clone();
        let barrier = barrier.clone();
        handles.push(std::thread::spawn(move || {
            barrier.wait();
            job.try_begin()
        }));
    }
    let wins = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|won| *won)
        .count();
    assert_eq!(wins, 1, "exactly one thread may begin the job");
    assert_eq!(job.snapshot().phase, EmbedPhase::Running);
}

#[test]
fn settle_maps_outcomes_to_terminal_states() {
    // Success
    let job = EmbedJob::new();
    job.try_begin();
    job.settle(EmbedOutcome::Ok(42));
    assert_eq!(job.snapshot().phase, EmbedPhase::Done);

    // Build error
    let job = EmbedJob::new();
    job.try_begin();
    job.settle(EmbedOutcome::BuildError("init BGE-M3 failed".into()));
    let s = job.snapshot();
    assert_eq!(s.phase, EmbedPhase::Failed);
    assert_eq!(s.error.as_deref(), Some("init BGE-M3 failed"));

    // Panic / join failure must not leave the job stuck Running.
    let job = EmbedJob::new();
    job.try_begin();
    job.settle(EmbedOutcome::Panicked("task panicked".into()));
    let s = job.snapshot();
    assert_eq!(s.phase, EmbedPhase::Failed);
    assert!(s.error.as_deref().unwrap().contains("panicked"));
}
