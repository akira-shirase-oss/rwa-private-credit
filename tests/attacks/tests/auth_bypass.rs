//! Authentication bypass: every route under `/v1` needs a real session or token.
#![allow(
    clippy::unwrap_used,
    reason = "test helpers: a panic is the failure report"
)]

mod common;

use common::spawn;
use serde_json::json;

#[tokio::test]
async fn protected_routes_refuse_anonymous_requests() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    for (method, path) in [
        ("GET", "/v1/me"),
        ("DELETE", "/v1/me"),
        ("POST", "/v1/workspaces"),
        ("GET", "/v1/workspaces/0190c0f4-3b8c-7a00-8000-000000000000"),
        (
            "GET",
            "/v1/workspaces/0190c0f4-3b8c-7a00-8000-000000000000/members",
        ),
        (
            "GET",
            "/v1/workspaces/0190c0f4-3b8c-7a00-8000-000000000000/tokens",
        ),
    ] {
        // Content-Type is set so extraction can't refuse first — the refusal asserted
        // here is the authentication refusal, 401. Handlers that validate their body
        // before the session check answer another 4xx — refused either way, never 2xx.
        let r = client
            .request(method.parse::<reqwest::Method>().unwrap(), s.url(path))
            .header("content-type", "application/json")
            .body("{}")
            .send()
            .await
            .unwrap();
        let status = r.status().as_u16();
        if method == "GET" {
            assert_eq!(status, 401, "{method} {path}");
        } else {
            assert!((400..500).contains(&status), "{method} {path} → {status}");
        }
    }
}

#[tokio::test]
async fn garbage_sessions_and_tokens_are_refused() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    for cookie in ["garbage", "rc_deadbeef", "../../../etc/passwd", ""] {
        let r = client
            .get(s.url("/v1/me"))
            .header("cookie", format!("rwacredit_session={cookie}"))
            .send()
            .await
            .unwrap();
        assert_eq!(r.status().as_u16(), 401, "cookie {cookie:?}");
    }
    for token in ["rc_", "rc_garbage", "notatoken", "rc_ almost right"] {
        let r = client
            .get(s.url("/v1/me"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap();
        assert_eq!(r.status().as_u16(), 401, "token {token:?}");
    }
}

#[tokio::test]
async fn public_routes_stay_strict() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    // Signup without an invite is refused, never anonymous-created.
    let r = client
        .post(s.url("/v1/signup"))
        .json(&json!({ "invite": "wrong", "email": "a@b.test", "password": common::PASSWORD }))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status().as_u16(), 403);
    // Verify with a made-up token is refused.
    let r = client
        .post(s.url("/v1/verify"))
        .json(&json!({ "token": "made-up-token" }))
        .send()
        .await
        .unwrap();
    assert!(r.status().is_client_error());
    // Sign-in with wrong credentials is refused without disclosing which part.
    let r = client
        .post(s.url("/v1/session"))
        .json(&json!({ "email": "nobody@example.test", "password": "x".repeat(12) }))
        .send()
        .await
        .unwrap();
    assert!(r.status().is_client_error());
}
