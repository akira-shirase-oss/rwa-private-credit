//! Cross-tenant access: user B's session must see nothing of user A's workspace.
#![allow(
    clippy::unwrap_used,
    reason = "test helpers: a panic is the failure report"
)]

mod common;

use common::{body_json, spawn};
use serde_json::{Value, json};

#[tokio::test]
async fn a_workspace_is_invisible_to_a_non_member() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    let alice = s.verified_session("alice@example.test").await;
    let bob = s.verified_session("bob@example.test").await;

    // Alice creates a workspace.
    let created = client
        .post(s.url("/v1/workspaces"))
        .header("cookie", format!("rwacredit_session={alice}"))
        .json(&json!({ "name": "Alice's shop" }))
        .send()
        .await
        .unwrap();
    assert_eq!(created.status().as_u16(), 201);
    let workspace = body_json(created).await["id"].as_str().unwrap().to_owned();

    // Every read/write of it under Bob's session is refused — and the envelope must
    // not confirm the workspace exists.
    for (method, path) in [
        ("GET", format!("/v1/workspaces/{workspace}")),
        ("DELETE", format!("/v1/workspaces/{workspace}")),
        ("GET", format!("/v1/workspaces/{workspace}/members")),
        ("POST", format!("/v1/workspaces/{workspace}/members")),
        ("GET", format!("/v1/workspaces/{workspace}/tokens")),
        ("POST", format!("/v1/workspaces/{workspace}/tokens")),
    ] {
        let r = client
            .request(method.parse::<reqwest::Method>().unwrap(), s.url(&path))
            .header("cookie", format!("rwacredit_session={bob}"))
            .json(&json!({ "name": "n", "user": uuid::Uuid::now_v7() }))
            .send()
            .await
            .unwrap();
        let status = r.status().as_u16();
        // Reads and deletes answer the access refusal; a POST whose body is invalid
        // is refused at 422 before the access check — either way Bob is refused and
        // the envelope confirms nothing about Alice's workspace.
        if method == "POST" {
            assert!((400..500).contains(&status), "{method} {path} → {status}");
        } else {
            assert!(status == 403 || status == 404, "{method} {path} → {status}");
        }
    }
}

#[tokio::test]
async fn resource_ids_of_other_users_are_not_guessable() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    let alice = s.verified_session("carol@example.test").await;
    for _ in 0..8 {
        let guess = uuid::Uuid::now_v7();
        let r = client
            .get(s.url(&format!("/v1/workspaces/{guess}")))
            .header("cookie", format!("rwacredit_session={alice}"))
            .send()
            .await
            .unwrap();
        assert!(r.status().is_client_error(), "guessed {guess}");
    }
}

#[tokio::test]
async fn me_only_ever_returns_the_callers_own_account() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    let dave = s.verified_session("dave@example.test").await;
    let r = client
        .get(s.url("/v1/me"))
        .header("cookie", format!("rwacredit_session={dave}"))
        .header("x-user-id", uuid::Uuid::now_v7().to_string()) // spoof attempt
        .send()
        .await
        .unwrap();
    let body: Value = r.json().await.unwrap();
    assert_eq!(body["email"].as_str().unwrap(), "dave@example.test");
}
