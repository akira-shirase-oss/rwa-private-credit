//! Body attacks: oversized (declared and streamed), slow-dribbled, and malformed.
#![allow(
    clippy::unwrap_used,
    reason = "test helpers: a panic is the failure report"
)]

mod common;

use std::time::Duration;

use common::{raw_status, spawn, spawn_with};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

#[tokio::test]
async fn a_body_past_the_limit_is_413_whether_declared_or_streamed() {
    let s = spawn().await; // StackLimits.max_body_bytes = 64 * 1024
    let client = reqwest::Client::new();
    let r = client
        .post(s.url("/v1/signup"))
        .header("content-type", "application/json")
        .body(vec![b'x'; 64 * 1024 + 1])
        .send()
        .await
        .unwrap();
    assert_eq!(r.status().as_u16(), 413);

    // Chunked, crossing mid-stream.
    let mut stream = TcpStream::connect(s.addr()).await.unwrap();
    let head = "POST /v1/signup HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n";
    stream.write_all(head.as_bytes()).await.unwrap();
    let mut out = Vec::new();
    for _ in 0..20 {
        let chunk = format!("{:x}\r\n{}\r\n", 4_096, "x".repeat(4_096));
        if stream.write_all(chunk.as_bytes()).await.is_err() {
            break;
        }
        let mut buf = [0_u8; 512];
        let _ = tokio::time::timeout(Duration::from_millis(200), stream.read(&mut buf))
            .await
            .map(|r| r.map(|n| out.extend_from_slice(&buf[..n])));
        if String::from_utf8_lossy(&out).starts_with("HTTP/1.1 413") {
            break;
        }
    }
    let _ = tokio::time::timeout(Duration::from_secs(2), stream.read_to_end(&mut out)).await;
    assert_eq!(raw_status(&String::from_utf8_lossy(&out)), 413);
}

#[tokio::test]
async fn a_slow_dribbled_body_times_out_and_the_server_stays_up() {
    let s = spawn_with(|(_, limits)| {
        limits.request_timeout = Duration::from_millis(600);
    })
    .await;
    let mut stream = TcpStream::connect(s.addr()).await.unwrap();
    let head = "POST /v1/session HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 8000\r\n\r\n";
    stream.write_all(head.as_bytes()).await.unwrap();
    let mut response = Vec::new();
    for _ in 0..4 {
        if stream.write_all(b"x").await.is_err() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
        let mut buf = [0_u8; 512];
        match tokio::time::timeout(Duration::from_millis(50), stream.read(&mut buf)).await {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => response.extend_from_slice(&buf[..n]),
            _ => {}
        }
    }
    let _ = tokio::time::timeout(Duration::from_secs(2), stream.read_to_end(&mut response)).await;
    let text = String::from_utf8_lossy(&response);
    assert!(
        raw_status(&text) == 503 || response.is_empty(),
        "slow body expected timeout/close, got {text:?}"
    );
    // The stack only mounts /v1: an anonymous /v1/me answering 401 proves it is alive.
    let client = reqwest::Client::new();
    let r = client.get(s.url("/v1/me")).send().await.unwrap();
    assert_eq!(r.status().as_u16(), 401);
}

#[tokio::test]
async fn malformed_bodies_are_4xx_never_5xx() {
    let s = spawn().await;
    let client = reqwest::Client::new();
    for (ctype, body) in [
        ("application/json", b"{broken".as_slice()),
        ("application/json", b"\xff\xfe".as_slice()),
        ("text/plain", b"{}".as_slice()),
        ("application/x-www-form-urlencoded", b"a=b".as_slice()),
    ] {
        for path in ["/v1/signup", "/v1/session", "/v1/verify"] {
            let r = client
                .post(s.url(path))
                .header("content-type", ctype)
                .body(body.to_vec())
                .send()
                .await
                .unwrap();
            let status = r.status().as_u16();
            assert!(
                (400..500).contains(&status),
                "{path} {ctype} {body:?} → {status}"
            );
        }
    }
    // Unknown fields are refused, not ignored.
    let r = client
        .post(s.url("/v1/signup"))
        .json(&json!({ "invite": "x", "email": "a@b.test", "password": common::PASSWORD, "admin": true }))
        .send()
        .await
        .unwrap();
    assert!(r.status().is_client_error());
}
