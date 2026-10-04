# Bliss Guidance: Last.fm

`lms-guidance-lastfm` is an independently installable Lyrion provider in the
**Bliss Guidance** family. It contributes bounded Last.fm similar-track and
similar-artist evidence to compatible Bliss hosts; it never chooses tracks on
its own or bypasses Bliss similarity, repeat, or quality rules.

Choose one provider-owned source on its settings page:

- **LastMix** uses the installed LastMix plugin and remains unavailable until that plugin is installed.
- **API Key** is the settings and secret-handling surface for the planned
  direct-acquisition path. The released native provider does not yet perform
  Last.fm HTTP/cache acquisition in this mode, so it currently contributes
  neutral guidance. The key is passed only through the child process
  environment; it never enters request JSON, artifacts, logs, or preview
  results.

The currently working end-to-end path is **LastMix**: LastMix obtains the
observations, the host resolves them to the frozen local candidate inventory,
and the native provider consumes the resulting artifact. The Lyrion provider
release is 0.2.0; direct API-key acquisition remains follow-up work.

Hosts discover the provider automatically but default it to disabled. Their
provider settings use these defaults unless a host explicitly overrides an
eligible policy control.

The native protocol is owned by
[bliss-playlist-guidance-spi](https://github.com/chrober/bliss-playlist-guidance-spi).
Provider conventions and UI rules are documented in
[lms-bliss-guidance-provider-kit](https://github.com/chrober/lms-bliss-guidance-provider-kit).
