# Changelog

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

