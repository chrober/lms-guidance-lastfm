# Native binaries

Release packaging places platform-specific `bliss-guidance-lastfm` binaries in
this directory. They are built by the
[bliss-guidance-lastfm](https://github.com/chrober/bliss-guidance-lastfm)
repository and are intentionally not committed here.

`NATIVE_RELEASE` pins the native release consumed by the plugin packaging
workflow. A workflow-dispatch input may override that pin explicitly.
