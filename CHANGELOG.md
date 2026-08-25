# Changelog

All notable changes to mcastsyslog are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### 2026-08-24
- **docs:** Amended `docs/SPEC.md` storage section — redb (a Rust crate) replaced
  by SQLite, so the whole application can be one native Swift target. The index
  design, the receive-time clustering key and the front-truncating retention
  delete are unchanged; they are properties of the access pattern, not of the
  store.
- **docs:** Added project `CLAUDE.md` with the work plan, architecture, version
  locations and the spec's non-negotiable properties.
