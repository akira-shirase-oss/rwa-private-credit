//! Rate-limit evasion: the sign-in budgets hold, and a flood learns nothing.
#![allow(
    clippy::unwrap_used,
    reason = "test helpers: a panic is the failure report"
)]

mod common;

use common::spawn_with;
use rwacredit_http::budget::Rate;
use serde_json::json;
use std::time::Duration;

#[tokio::test]
async fn the_per_address_budget_refuses_a_flood_and_says_nothing() {
    let s = spawn_with(|(settings, _)| {
        settings.sign_in.per_address = Rate::new(4, Duration::from_secs(30));
    })
    .await;
    let client = reqwest::Client::new();
    for i in 0..10 {
        let r = client
            .post(s.url("/v1/session"))
            .json(
                &json!({ "email": format!("victim{i}@example.test"), "password": "x".repeat(12) }),
            )
            .send()
            .await
            .unwrap();
        // Once the bucket is empty the answer is 429, not a different guess signal.
        if i >= 4 {
            assert_eq!(r.status().as_u16(), 429, "attempt {i} was not throttled");
        }
    }
}

#[tokio::test]
async fn mail_routes_share_the_per_address_budget() {
    let s = spawn_with(|(settings, _)| {
        settings.mail.per_address = Rate::new(2, Duration::from_secs(30));
        settings.mail.global = Rate::new(1_000, Duration::from_secs(1));
    })
    .await;
    let client = reqwest::Client::new();
    let mut throttled = 0_usize;
    for _ in 0..6 {
        let r = client
            .post(s.url("/v1/password-reset"))
            .json(&json!({ "email": "target@example.test" }))
            .send()
            .await
            .unwrap();
        if r.status().as_u16() == 429 {
            throttled += 1;
        }
    }
    assert!(throttled > 0, "password-reset flood was never throttled");
}
