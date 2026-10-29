# Bliss Guidance: Last.fm

`lms-guidance-lastfm` is an independently installable, passive Lyrion guidance
provider in the **Bliss Guidance** family. It contributes bounded Last.fm
similar-track and similar-artist evidence when a compatible Bliss host invokes
it. It does not create mixes, reorder tracks, or control playback by itself;
another plugin must discover, enable, and use it.

## How it works

Choose one provider-owned source on its settings page:

- **LastMix** uses the installed LastMix plugin and remains unavailable until that plugin is installed.
- **API Key** lets the native provider acquire and persist Last.fm relations
  during SPI preparation. The key is passed only through the child-process
  environment; it never enters request JSON, artifacts, logs, or preview
  results.

  For this source, choose a key configured in this provider or the custom API
  key saved in LastMix. The saved custom key must be non-empty; LastMix need
  not be enabled, and its custom-key checkbox and shared secret are not needed. The key
  is read when needed rather than copied, and both plugins share its request
  limits. A missing selected key does not trigger a fallback to another key.

With **LastMix**, the Lyrion provider obtains observations, the host resolves
them to the frozen local candidate inventory, and the native provider consumes
the resulting artifact. With **API Key**, the native provider queries only the
frozen source anchors during `prepare`, persists complete observations in its
SQLite graph, and then
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
    LastMixPrefs["Lyrion preferences: plugin.lastmix"] -.->|optional custom API key| Perl
    Perl -->|writes JSON and computes SHA-256| Artifact["Job artifact: resolved-lastfm-evidence-v1"]
    Perl -->|native config and artifact descriptor| Host
    Host -->|SPI prepare and score JSONL| Native["bliss-guidance-lastfm executable"]
    Artifact -.->|trusted, hash-bound input| Native
    Native -->|direct prepare only| LastFm["Last.fm API"]
    Native <--> Graph["Provider SQLite graph: lastfm-guidance.sqlite"]
    Perl --> Roots["Frozen library-artist roots JSON"]
    Perl --> Request["Trusted graph request JSON"]
    Roots -.-> Native
    Request -.-> Native
    Native --> Progress["Versioned graph progress JSONL"]
    Progress -.-> Perl
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
  mode it instead supplies only provider-owned graph paths and non-secret
  request limits plus the launch-only environment variable.
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
    participant C as Provider SQLite graph
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
        P-->>H: Non-secret graph paths, policy, and request limits
        P-->>N: API key in child-process environment
        H->>N: prepare JSONL(options, frozen anchors)
        N->>C: Read fresh stored relations
        N->>A: Fetch missing or expired anchor relations
        A-->>N: Similar tracks and artists or tolerated failures
        N->>C: Commit refreshed relations transactionally
    end
    H->>N: score JSONL(anchors, bounded candidates)
    N-->>H: Guidance, selection_trace_v1, diagnostics
    H->>S: Combine with Bliss and publish only after acceptance
```

In **API Key** mode no LastMix artifact is created. Remote requests are limited
to `prepare`; `score` is deterministic for the prepared session and performs no
network I/O. Missing graph entries, invalid responses, rate limits, timeouts, and
offline operation degrade to partial or neutral guidance rather than blocking
the Bliss result.

Direct artist lookups also refresh local library membership independently of the
host that requested them. This reads the Lyrion library locally and does not
start a bulk Last.fm update. The full membership refresh runs in the background;
the local-artists-only scope first checks returned artists against the current
local library before saving results, so newly added artists are not incorrectly
filtered out. If the local
library cannot be read, local-only results are not persisted against stale
membership; the current lookup can still supply guidance for that session.

## Offline artist graph and manual update

When **API Key** is selected, the settings page also owns the offline graph
policy, storage scope, and the number of similar artists requested per source.
It shows graph coverage, physical SQLite storage, and the separately accounted
retained Last.fm data size, and can start a full library-artist update.
Optional refresh targets control when results and empty results are rechecked,
using the last successful validation time. Empty fields use Last.fm freshness
headers, falling back to 30 days for results and 7 days for empty results. A
custom target applies to both manual updates and direct guidance preparation;
it does not schedule scans. Existing HTTP validators are used for revalidation.
The current cache implementation does not yet handle every HTTP cache directive.
The update:

- snapshots distinct local Lyrion contributors with their available Artist
  MBIDs;
- runs native synchronization asynchronously, with the API key present only in
  the child environment;
- reports start time, duration, current/total artists, request/cache/change
  counts, rate-limit pauses, errors, and completion without reloading the
  settings page; and
- supports pause/resume, cancellation, compaction, and confirmed deletion.

**Clean up and compact stored data** takes a fresh Lyrion artist snapshot. It
repairs only encoding errors that uniquely match that snapshot, marks repaired
observations for revalidation, and removes artists with no remaining library or
similarity references. Ambiguous matches are left unchanged and counted in the
result. Referenced external artists and their similarity information are kept.
The saved result limit and storage scope still trim relations during compaction.
The operation can remove data and asks for confirmation; it makes no Last.fm
requests.

The configurable retained-data budget defaults to 100 decimal MB and applies to canonical Last.fm artist-similarity data
kept in SQLite: returned artist identities, ranks, scores, and HTTP validators.
Track similarities may use the separate short-lived JSON cache but are never
persisted in SQLite. SQLite pages, indexes, WAL/SHM files, and Lyrion-owned
membership metadata are not treated as Last.fm data. The settings page displays
both the logical retained-data total and the physical SQLite footprint.
The separate JSON track cache contributes the UTF-8 size of retained result
values, excluding JSON field names, punctuation, cache keys and timestamps.
Numbers use their canonical decimal representation.
Expired track entries are pruned under a file lock when cache usage is checked
or the cache is written; a graph status check can therefore clean this cache.
An unreadable or unrecognized cache is preserved and reported as an accounting
error instead of assigning it a guessed size. Normal guidance skips writing new cache data when the combined budget
is full; independent concurrent processes can still race between the SQLite and
JSON size checks. This accounting is an estimate, not a legal determination.
Last.fm's [API terms](https://www.last.fm/api/tos) require prior written consent
to exceed its 100 MB reasonable-usage cap. The displayed accounting is an
estimate and does not establish compliance with those terms.

Normal **Save** remains explicit. Maintenance buttons never persist unrelated
unsaved form edits. Graph controls are hidden for **LastMix**, and that path
does not open, populate, migrate, compact, delete, or report the graph.

The public settings intentionally expose **Online with cache** and **Offline
preferred**. A strict native offline-only policy exists for controlled testing,
but is not offered in the plugin UI until the applicable Last.fm terms permit
shipping it as a supported user mode.

```mermaid
sequenceDiagram
    participant U as User
    participant W as Provider settings page
    participant P as Last.fm provider plugin
    participant D as Lyrion database
    participant R as Roots and request JSON
    participant N as Native maintenance command
    participant A as Last.fm API
    participant G as SQLite graph
    participant J as Progress JSONL

    U->>W: Update offline Last.fm library
    W->>P: JSON-RPC start
    P->>D: Stream distinct local contributors and Artist MBIDs
    P->>R: Atomically write frozen roots and trusted request
    P->>N: Start graph sync with API key in child environment
    N->>G: Store current library membership
    loop Missing or refresh-eligible roots
        N->>G: Read observation and validators
        N->>A: artist.getSimilar at bounded rate
        A-->>N: Complete response or tolerated failure
        N->>G: Commit observation and directed edges
        N->>J: Append versioned progress
        W->>P: JSON-RPC status
        P->>J: Read latest complete event
        P-->>W: Current progress and duration
    end
```

## Logging

The plugin registers the `plugin.guidancelastfm` log category. At information
level it reports similar-track and similar-artist requests, result counts,
cache use, tolerated failures, and preparation summaries. Debug level adds
sanitized request/response JSON, returned track or artist relations, and
candidate-scoring coverage. Fatal provider or host startup failures remain in
the calling host's error log because no provider session exists to report them.

LastMix acquisition logs directly through this category. API Key acquisition
and native scoring return structured events through
`guidance_log_event_v1`; the host transports them back to this plugin for the
same provider-owned rendering. API keys and signatures are always redacted.
When a lookup fails, the existing warning is followed at debug level by the
operation, source and available failure context, such as HTTP status, Last.fm
error code, retryability or response-parsing stage. Offline library update
failures and pauses include the artist and position being processed.

## Installation

Install **Bliss Guidance: Last.fm** through
[chrober's LMS Plugin Repository](https://github.com/chrober/lms-plugins), then
enable the provider in a compatible host. Install and configure LastMix
separately when you want to use the LastMix source.

Configure the source and provider-owned guidance defaults on the provider's
own settings page. Compatible hosts may save their own source and guidance
overrides; the API key is never exposed to host settings or request artifacts.
