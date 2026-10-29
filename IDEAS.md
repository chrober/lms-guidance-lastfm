# Ideas

These are ideas for future exploration, not commitments or implemented features.

## Browse similar artists using the offline graph

Offer a way to explore Last.fm artist similarities stored in the provider's
offline SQLite graph from Lyrion, potentially starting from an artist's context
menu. Users could follow related artists and browse their music without needing
to start a mix or a playlist job.

### Context

- [MusicArtistInfo](https://github.com/michaelherger/MusicArtistInfo) already
  offers related artists using Last.fm's `artist.getInfo` response and its own
  cache; see its [artist menu](https://github.com/michaelherger/MusicArtistInfo/blob/master/ArtistInfo.pm)
  and [Last.fm integration](https://github.com/michaelherger/MusicArtistInfo/blob/master/LFM.pm).
- [Material Skin](https://github.com/CDrummond/lms-material) separately shows
  similar artists using Last.fm's `artist.getSimilar` and its own cache; see
  its [server implementation](https://github.com/CDrummond/lms-material/blob/master/MaterialSkin/Plugin.pm)
  and [artist browse view](https://github.com/CDrummond/lms-material/blob/master/MaterialSkin/HTML/material/html/js/browse-functions.js).
- Neither of those implementations currently reads this provider's offline
  graph. An additional view could work offline, use the stored result order and
  result limit, and distinguish artists in the user's library from others.

The graph contains Last.fm similarity observations, not Bliss acoustic
similarity. An A-to-B observation does not imply that B-to-A was fetched or
has the same rank. The available data depends on the graph's coverage and
stored-artist scope.

### Possibilities and open questions

- Add a provider-owned Lyrion artist-info/context contribution; check its
  placement in Material Skin and other clients, including whether it appears
  directly or under **More**. Avoid requiring changes to Material Skin or
  MusicArtistInfo.
- Decide whether to show local artists only or present local and external
  artists separately. For local results, consider the active virtual library;
  for external results, consider search or artist information. Clicking a
  local result could open its albums, and further navigation could follow
  stored outgoing similarities.
- Resolve identities by artist MBID where possible; use names cautiously and
  do not silently merge ambiguous identities. Check actual Lyrion library
  membership rather than assuming the stored membership snapshot is current.
- Define missing, empty and stale-result behavior, including whether a user
  may request an online lookup. Respect the provider's retrieval policy and
  keep offline-only use genuinely offline.
- Decide how much provenance, age and Last.fm attribution to show. Check the
  applicable Last.fm terms before making data available for browsing.
- Choose a read-only graph access interface and keep browsing responsive without
  blocking the Lyrion event loop. Consider database availability, concurrent
  maintenance, paging and the existing provider ownership boundaries.

No UI, filtering or online-fallback choice has been decided yet.
