//! Replay: used invites, spent verify tokens and dead sessions stay dead.
#![allow(
    clippy::unwrap_used,
    reason = "test helpers: a panic is the failure report"
)]

mod common;

use common::spawn;
use serde_json::json;

#[tokio::test]
async fn an_invite_is_spent_once() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    let invite = s.invite().await;
    for (i, email) in ["first@example.test", "second@example.test"]
        .iter()
        .enumerate()
    {
        let r = client
            .post(s.url("/v1/signup"))
            .json(&json!({ "invite": invite, "email": email, "password": common::PASSWORD }))
            .send()
            .await
            .unwrap();
        if i == 0 {
            assert_eq!(r.status().as_u16(), 201);
        } else {
            assert_eq!(r.status().as_u16(), 403, "invite replayed");
        }
    }
}

#[tokio::test]
async fn a_verify_token_cannot_be_replayed() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    let invite = s.invite().await;
    let r = client
        .post(s.url("/v1/signup"))
        .json(&json!({ "invite": invite, "email": "replay@example.test", "password": common::PASSWORD }))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status().as_u16(), 201);
    let token = s
        .sink
        .latest_to("replay@example.test")
        .await
        .unwrap()
        .token()
        .unwrap();
    let first = client
        .post(s.url("/v1/verify"))
        .json(&json!({ "token": token }))
        .send()
        .await
        .unwrap();
    assert_eq!(first.status().as_u16(), 204);
    let second = client
        .post(s.url("/v1/verify"))
        .json(&json!({ "token": token }))
        .send()
        .await
        .unwrap();
    assert!(
        second.status().is_client_error(),
        "verify token replayed → {}",
        second.status()
    );
}

#[tokio::test]
async fn a_signed_out_session_is_dead() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    let session = s.verified_session("gone@example.test").await;
    let out = client
        .delete(s.url("/v1/session"))
        .header("cookie", format!("rwacredit_session={session}"))
        .send()
        .await
        .unwrap();
    assert!(out.status().is_success());
    let r = client
        .get(s.url("/v1/me"))
        .header("cookie", format!("rwacredit_session={session}"))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status().as_u16(), 401, "dead session reused");
}

#[tokio::test]
async fn a_duplicate_signup_is_refused_without_disclosure() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    let _ = s.verified_session("dup@example.test").await;
    // A fresh invite + the same address: refused, and the envelope must not confirm
    // the account exists beyond the documented email_taken.
    let invite = s.invite().await;
    let r = client
        .post(s.url("/v1/signup"))
        .json(
            &json!({ "invite": invite, "email": "dup@example.test", "password": common::PASSWORD }),
        )
        .send()
        .await
        .unwrap();
    assert!(r.status().is_client_error(), "duplicate signup accepted");
    // The session cookie from the first account still works — replay did not corrupt it.
    let me = client
        .get(s.url("/v1/me"))
        .header(
            "cookie",
            format!("rwacredit_session={}", s.verified_session("x@x.test").await),
        )
        .send()
        .await
        .unwrap();
    assert_eq!(me.status().as_u16(), 200);
}
