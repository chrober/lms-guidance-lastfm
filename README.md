# Bliss Guidance: Last.fm

`lms-guidance-lastfm` is an independently installable, passive Lyrion guidance
provider in the **Bliss Guidance** family. It contributes bounded Last.fm
similar-track and similar-artist evidence when a compatible Bliss host invokes
it. It does not create mixes, reorder tracks, or control playback by itself;
another plugin must discover, enable, and use it.

## How it works

Choose one provider-owned source on its settings page:

- **LastMix** uses the installed LastMix plugin and remains unavailable until that plugin is installed.
- **API Key** lets the native provider acquire and cache Last.fm relations
  during SPI preparation. The key is passed only through the child-process
  environment; it never enters request JSON, artifacts, logs, or preview
  results.

With **LastMix**, the Lyrion provider obtains observations, the host resolves
them to the frozen local candidate inventory, and the native provider consumes
the resulting artifact. With **API Key**, the native provider queries only the
frozen source anchors during `prepare`, persists a bounded TTL cache, and then
scores the host's Bliss-qualified candidate batches without network access.

Hosts discover the provider automatically but default it to disabled. Their
provider settings use these defaults unless a host explicitly overrides an
eligible policy control.

The compatible host plugins currently include
[Better Call Bliss](https://github.com/chrober/lms-better-call-bliss) and
[Bliss Mixer Lab](https://github.com/chrober/lms-blissmixer-lab). Both discover
this provider but leave it disabled until you explicitly enable it.

The native implementation is
[`bliss-guidance-lastfm`](https://github.com/chrober/bliss-guidance-lastfm).
The native protocol is owned by
[`bliss-playlist-guidance-spi`](https://github.com/chrober/bliss-playlist-guidance-spi).
Provider conventions and UI rules are documented in
[`lms-bliss-guidance-provider-kit`](https://github.com/chrober/lms-bliss-guidance-provider-kit).

## Architecture

```mermaid
flowchart LR
    Settings["LastFmGuidance/HTML/.../lastfmguidance.html"] --> Prefs["Lyrion preferences: plugin.guidancelastfm"]
    Prefs --> Perl["LastFmGuidance/Provider.pm"]
    Host["Compatible Bliss host"] -->|descriptor, defaults, policy| Perl
    LastMix["LastMix plugin / LastMix API"] -->|similar-track and similar-artist observations| Perl
    Perl -->|writes JSON and computes SHA-256| Artifact["Job artifact: resolved-lastfm-evidence-v1"]
    Perl -->|native config and artifact descriptor| Host
    Host -->|SPI prepare and score JSONL| Native["bliss-guidance-lastfm executable"]
    Artifact -.->|trusted, hash-bound input| Native
    Native -->|direct prepare only| LastFm["Last.fm API"]
    Native <--> Cache["Provider TTL cache"]
    Native -->|bounded guidance and selection_trace_v1| Host
    Host -->|accepted result| Sinks["preview report / saved playlist / player queue"]
    Prefs -.->|API key in launch environment only| Native
```

The provider-owned files and streams are:

- `LastFmGuidance/Plugin.pm` exposes the discoverable provider, while
  `LastFmGuidance/Settings.pm` registers its settings page.
- `LastFmGuidance/HTML/EN/plugins/LastFmGuidance/settings/lastfmguidance.html`
  renders that page; persisted values live in the Lyrion
  `plugin.guidancelastfm` preference namespace.
- `LastFmGuidance/Provider.pm` publishes the descriptor and defaults, resolves
  host/job overrides, calls LastMix in LastMix mode, and writes the temporary
  `resolved-lastfm-evidence-v1` JSON artifact supplied by the host. In API-key
  mode it instead supplies only non-secret cache and request limits plus the
  launch-only environment variable.
- `bliss-guidance-lastfm` reads that artifact and the bounded candidate/context
  messages from SPI JSONL on stdin, then returns bounded guidance,
  `selection_trace_v1`, and diagnostics on stdout. There is no separate
  `prepare.options` file: native options are part of the SPI `prepare` message.
- The host consumes the response and is the only component that writes preview
  results, playlists, or player queues.

## Runtime flow

```mermaid
sequenceDiagram
    participant U as User
    participant H as Bliss host
    participant P as Last.fm provider plugin
    participant L as LastMix
    participant A as Last.fm API
    participant F as resolved-lastfm-evidence-v1 JSON
    participant C as Direct-mode TTL cache
    participant N as Native provider
    participant S as Host result sinks

    U->>H: Enable provider and choose source/policy
    H->>P: Read descriptor, defaults, and status
    P-->>H: Provider metadata and effective defaults
    alt LastMix source
        H->>P: Acquire artifacts(source tracks, candidates, artifact path)
        P->>L: Query similar tracks and similar artists
        L-->>P: Observations or tolerated failures
        P->>F: Write resolved candidate edges
        P->>F: Reopen, hash, and verify artifact
        P-->>H: Artifact path, SHA-256, statistics
        H->>N: prepare JSONL(options, anchors, artifact descriptor)
        N->>F: Read and verify hash-bound evidence
    else API Key source
        P-->>H: Non-secret cache and request limits
        P-->>N: API key in child-process environment
        H->>N: prepare JSONL(options, frozen anchors)
        N->>C: Read fresh cached relations
        N->>A: Fetch missing or expired anchor relations
        A-->>N: Similar tracks and artists or tolerated failures
        N->>C: Merge refreshed relations safely
    end
    H->>N: score JSONL(anchors, bounded candidates)
    N-->>H: Guidance, selection_trace_v1, diagnostics
    H->>S: Combine with Bliss and publish only after acceptance
```

In **API Key** mode no LastMix artifact is created. Remote requests are limited
to `prepare`; `score` is deterministic for the prepared session and performs no
network I/O. Cache misses, invalid responses, rate limits, timeouts, and
offline operation degrade to partial or neutral guidance rather than blocking
the Bliss result.

## Installation

Install **Bliss Guidance: Last.fm** through
[chrober's LMS Plugin Repository](https://github.com/chrober/lms-plugins), then
enable the provider in a compatible host. Install and configure LastMix
separately when you want to use the LastMix source.

Configure the source and provider-owned guidance defaults on the provider's
own settings page. Host documentation describes how to enable the provider and
optionally override those defaults for a particular host or job.
