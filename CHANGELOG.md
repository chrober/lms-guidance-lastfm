# Changelog

## 0.3.0 - 2026-10-27

- Add a versioned, MBID-first SQLite artist-similarity graph for the API-key
  source, with read-through updates, freshness validators, migration,
  configurable result limits and storage scope. Track results remain in the
  separate expiring JSON cache.
- Add an API-key-only background library-artist update with live status,
  pause/resume, cancellation, compaction and confirmed deletion on the provider
  settings page.
- Keep LastMix artifact acquisition isolated from every graph path and reject
  pre-graph native binaries only when API Key behavior is selected.
- Count unique resolved library artists consistently in scan progress and
  coverage, without merging distinct MBIDs, and label an empty result limit
  as unlimited.
- Count retained Last.fm cache values without JSON formatting and expire old
  track-cache entries before accounting. Include targeted artist cleanup and
  configurable freshness and storage controls.

## 0.2.3 - 2026-10-17

- Bundle native `bliss-guidance-lastfm` 0.1.3 with direct and artifact
  acquisition plus the Last.fm track and artist policies used by the hosts.
- Reject stale native binaries that do not publish the required acquisition
  modes and channel-policy capabilities, instead of failing during a mix.
- Keep the packaged native release in one tracked pin so future provider
  releases cannot silently fall back to an obsolete binary.

## 0.2.2 - 2026-10-16

- Allow each compatible host to save its own LastMix/API Key source override
  while keeping the API key itself private to this provider.
- Relay structured native-provider warning, information, and debug events
  through the provider-owned `plugin.guidancelastfm` Lyrion log category.
- Report Last.fm track and artist lookup requests, cache or fresh-result counts,
  tolerated failures, preparation summaries, and scoring coverage while
  preserving API-key redaction.
- Pass the effective Lyrion log level to the native provider so detailed JSON
  and result diagnostics are emitted only at debug level.
- Support both acquisition choices through the same provider contract:
  LastMix supplies a resolved artifact, while API Key mode performs bounded,
  cache-backed native acquisition during `prepare` and keeps scoring
  network-free.

