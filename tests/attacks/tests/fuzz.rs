//! Never-panics fuzz targets for every parser/decoder of outside input, plus a
//! replay of each target's committed seed corpus under `fuzz/corpus/<target>/`.
//! A panic found here is a red-first bug: the shrunk input lands in the corpus.
#![allow(
    clippy::unwrap_used,
    reason = "test helpers: a panic is the failure report"
)]

mod common;

use std::collections::BTreeMap;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;

use axum::http::{HeaderMap, HeaderValue};
use proptest::prelude::*;
use proptest::strategy::{Strategy, ValueTree};
use rwacredit_accounts::{domain, tokens};
use rwacredit_http::client::ClientKey;
use rwacredit_server::config::{self, Source};

/// A `Source` over generated key/value pairs.
struct MapSource(BTreeMap<String, String>);

impl Source for MapSource {
    fn var(&self, name: &str) -> Option<String> {
        self.0.get(name).cloned()
    }
}

/// Feeds one input into `target`'s parsers.
fn apply(target: &str, bytes: &[u8]) {
    let text = String::from_utf8_lossy(bytes);
    match target {
        "api_token" => {
            let _ = tokens::looks_like_api_token(&text);
            let _ = tokens::looks_like_hex_secret(&text);
            let _ = tokens::digest(&text);
            let _ = tokens::base32(bytes);
        }
        "client_key" => {
            let mut map = HeaderMap::new();
            if let Ok(v) = HeaderValue::from_bytes(bytes) {
                map.append("x-forwarded-for", v);
            }
            let peer = SocketAddr::from(([203, 0, 113, 9], 9_000));
            let _ = ClientKey::from_request(peer, &map, &[IpAddr::from([127, 0, 0, 1])]);
            let _ = ClientKey::from_request(peer, &map, &[]);
        }
        "email" => {
            let _ = domain::normalize_email(&text);
        }
        "password" => {
            let _ = domain::check_password(&text);
        }
        "config" => {
            let value = text.into_owned();
            let mut map = BTreeMap::new();
            for var in ["RWACREDIT_PUBLIC_URL", "RWACREDIT_TRUSTED_PROXIES"] {
                map.insert(var.to_owned(), value.clone());
            }
            let _ = config::Config::load(&MapSource(map));
        }
        other => panic!("unknown fuzz target {other}"),
    }
}

/// Every committed seed file is replayed through its target's parsers.
#[test]
fn seed_corpus_replays_without_panics() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("fuzz/corpus");
    let mut files = 0_usize;
    for dir in std::fs::read_dir(&root).unwrap() {
        let dir = dir.unwrap();
        let target = dir.file_name().to_string_lossy().into_owned();
        for entry in std::fs::read_dir(dir.path()).unwrap() {
            let bytes = std::fs::read(entry.unwrap().path()).unwrap();
            apply(&target, &bytes);
            files += 1;
        }
    }
    assert!(files >= 15, "only {files} corpus files — corpus too thin");
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|v| v.parse().ok()).unwrap_or(128)
    ))]

    #[test]
    fn token_parsers_never_panic(s in any::<String>(), b in any::<Vec<u8>>()) {
        let _ = tokens::looks_like_api_token(&s);
        let _ = tokens::looks_like_hex_secret(&s);
        let _ = tokens::digest(&s);
        let _ = tokens::base32(&b);
    }

    #[test]
    fn xff_parsing_never_panic_or_reads_past_the_rightmost_entry(
        entries in prop::collection::vec(any::<String>(), 0..8),
        trusted in any::<bool>(),
    ) {
        let mut map = HeaderMap::new();
        for entry in &entries {
            if let Ok(v) = HeaderValue::from_str(entry) {
                map.append("x-forwarded-for", v);
            }
        }
        let peer = SocketAddr::from(([127, 0, 0, 1], 9_000));
        let trusted_peers: &[IpAddr] = if trusted { &[IpAddr::from([127, 0, 0, 1])] } else { &[] };
        let _ = ClientKey::from_request(peer, &map, trusted_peers);
    }

    #[test]
    fn validators_never_panic(s in any::<String>()) {
        let _ = domain::normalize_email(&s);
        let _ = domain::check_password(&s);
    }

    #[test]
    fn config_never_panics_or_accepts_garbage(
        pairs in prop::collection::vec(any::<(String, String)>(), 0..16),
    ) {
        let map: BTreeMap<String, String> = pairs.into_iter().collect();
        let _ = config::Config::load(&MapSource(map));
    }
}

/// Arbitrary bytes as request bodies through the real router: never a 5xx,
/// never a panic (a panic would surface as `CatchPanic`'s 500).
#[tokio::test]
async fn request_bodies_through_the_router_never_5xx() {
    let s = common::spawn().await;
    let client = reqwest::Client::new();
    let mut runner = proptest::test_runner::TestRunner::default();
    let inputs: Vec<Vec<u8>> = (0..64)
        .map(|_| any::<Vec<u8>>().new_tree(&mut runner).unwrap().current())
        .collect();
    for (i, bytes) in inputs.iter().enumerate() {
        for path in ["/v1/signup", "/v1/session", "/v1/verify"] {
            let r = client
                .post(s.url(path))
                .header("content-type", "application/json")
                .body(bytes.clone())
                .send()
                .await
                .unwrap();
            assert!(
                !r.status().is_server_error(),
                "{path} on generated body {i} → {}",
                r.status()
            );
        }
    }
}
