//! Conservative fuzzy slug→source matching (helps books whose dir-slug was
//! truncated/reworded still link to their source PDF, without false positives).
use std::collections::HashSet;

use reader_core::fuzzy_pick_source;

fn set(items: &[&str]) -> HashSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

#[test]
fn matches_reworded_title_same_author_unique() {
    let cands = set(&[
        "bennett-birth-of-the-museum-1995",
        "foucault-discipline-and-punish-1977",
    ]);
    assert_eq!(
        fuzzy_pick_source("bennett-the-birth-of-the-museum-1995", &cands).as_deref(),
        Some("bennett-birth-of-the-museum-1995"),
    );
}

#[test]
fn rejects_same_author_different_title() {
    let cands = set(&["smith-the-quantified-mind-2015"]);
    assert_eq!(fuzzy_pick_source("smith-the-digital-body-2020", &cands), None);
}

#[test]
fn rejects_ambiguous_ties() {
    // Same author + identical title tokens, only the year differs → no unique
    // winner → refuse (never guess between editions).
    let cands = set(&[
        "lupton-quantified-self-tracking-2016",
        "lupton-quantified-self-tracking-2018",
    ]);
    assert_eq!(
        fuzzy_pick_source("lupton-quantified-self-tracking-2020", &cands),
        None,
    );
}

#[test]
fn rejects_too_little_title_signal() {
    // Only one significant title token ("body") after dropping lastname + year
    // → not enough signal to risk a match.
    let cands = set(&["smith-the-body-and-society-2020"]);
    assert_eq!(fuzzy_pick_source("smith-body-2020", &cands), None);
}

#[test]
fn requires_same_lastname() {
    let cands = set(&["jones-quantified-self-tracking-2016"]);
    assert_eq!(
        fuzzy_pick_source("lupton-quantified-self-tracking-2016", &cands),
        None,
    );
}

#[test]
fn rejects_subset_title_with_distant_year() {
    // "Time and Space in the Internet Age" (a different, later Kern book) must
    // NOT match "The Culture of Time and Space" just because {time,space} is a
    // subset of {culture,time,space}. The 63-year gap is the tell.
    let cands = set(&["kern-culture-of-time-and-space-1983"]);
    assert_eq!(
        fuzzy_pick_source("kern-time-and-space-in-1920", &cands),
        None,
    );
}

#[test]
fn matches_truncated_title_with_close_year() {
    // Full title "Queer Phenomenology: Orientations…" truncated in the vault
    // slug — partial overlap, but same year → trust it.
    let cands = set(&["ahmed-queer-phenomenology-2006"]);
    assert_eq!(
        fuzzy_pick_source("ahmed-orientations-queer-phenomenology-2006", &cands).as_deref(),
        Some("ahmed-queer-phenomenology-2006"),
    );
}

#[test]
fn matches_identical_title_despite_distant_year() {
    // A year typo (1883 for 1983) leaves the title identical → still a match;
    // the year gate only applies to partial-title overlaps.
    let cands = set(&["kern-culture-of-time-and-space-1983"]);
    assert_eq!(
        fuzzy_pick_source("kern-culture-of-time-and-space-1883", &cands).as_deref(),
        Some("kern-culture-of-time-and-space-1983"),
    );
}
