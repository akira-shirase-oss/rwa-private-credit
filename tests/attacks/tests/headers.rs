//! Header spoofing: `X-Forwarded-For` is believed only from a trusted proxy, and
//! only its right-most entry — forged entries to its left never shift the
//! sign-in budget off the real client.
#![allow(
    clippy::unwrap_used,
    reason = "test helpers: a panic is the failure report"
)]

mod common;

use common::spawn_with;
use rwacredit_accounts::Settings;
use rwacredit_http::budget::Rate;
use serde_json::json;
use std::time::Duration;

/// Sends a bad sign-in attempt; returns the status.
async fn bad_signin(client: &reqwest::Client, base: &str, xff: Option<&str>) -> u16 {
    let mut r = client
        .post(format!("{base}/v1/session"))
        .json(&json!({ "email": "flooder@example.test", "password": "x".repeat(12) }));
    if let Some(hop) = xff {
        r = r.header("x-forwarded-for", hop);
    }
    r.send().await.unwrap().status().as_u16()
}

#[tokio::test]
async fn xff_from_an_untrusted_peer_does_not_evasion_the_signin_budget() {
    // trusted_proxies empty → the peer is the client; XFF is decoration.
    let s = spawn_with(|(settings, _)| {
        settings.trusted_proxies = vec![];
        settings.sign_in.per_address = Rate::new(6, Duration::from_secs(30));
    })
    .await;
    let client = reqwest::Client::new();
    let mut throttled = 0_usize;
    for i in 0..12 {
        // Each attempt spoofs a different "client": the budget must not move.
        let status = bad_signin(&client, &s.base, Some(&format!("198.51.100.{i}"))).await;
        if status == 429 {
            throttled += 1;
        }
    }
    assert!(throttled > 0, "rotating XFF evaded the per-address budget");
}

#[tokio::test]
async fn from_a_trusted_proxy_only_the_rightmost_xff_entry_is_believed() {
    // The real peer is 127.0.0.1 (the test is the proxy); declare it trusted.
    let s = spawn_with(|(settings, _): &mut (Settings, _)| {
        settings.trusted_proxies = vec![std::net::IpAddr::from([127, 0, 0, 1])];
        settings.sign_in.per_address = Rate::new(6, Duration::from_secs(30));
    })
    .await;
    let client = reqwest::Client::new();
    let mut throttled = 0_usize;
    for i in 0..12 {
        // Forged entries on the left, the same true client on the right: still bucketed.
        let status = bad_signin(&client, &s.base, Some(&format!("10.0.0.{i}, 203.0.113.7"))).await;
        if status == 429 {
            throttled += 1;
        }
    }
    assert!(
        throttled > 0,
        "left-side forged XFF entries evaded the budget"
    );

    // And when the right-most entry is a fresh address each time, the budget follows
    // the claimed client — proving only the last hop counts.
    let s2 = spawn_with(|(settings, _): &mut (Settings, _)| {
        settings.trusted_proxies = vec![std::net::IpAddr::from([127, 0, 0, 1])];
        settings.sign_in.per_address = Rate::new(6, Duration::from_secs(30));
    })
    .await;
    let mut first_seven_ok = true;
    for i in 0..7 {
        let status = bad_signin(&client, &s2.base, Some(&format!("203.0.113.{i}"))).await;
        if status == 429 {
            first_seven_ok = false;
        }
    }
    assert!(
        first_seven_ok,
        "right-most rotation did not move the budget — the wrong entry is believed"
    );
}
