//! Penetration-test regressions and fuzz targets, modelled on
//! `labs/minibtc/tests/attacks`. Every test issues a real request against a running
//! instance (real TCP, real middleware, the real SMTP adapter into a fake sink) and
//! asserts the refusal; `tests/fuzz.rs` feeds every parser of outside input its
//! committed seed corpus plus generated cases. A product's copy owns this suite.
