### Internal
- **One function places a release's sidecars (#1420).** `Cinder.Library.Sidecars.link/2`, which
  no code outside the tests called, is gone. The staged import's commit hands the sidecars it
  listed to `Cinder.Library.Sidecars.link_listed/2`, and the `Cinder.Subtitles` typedoc for the
  sidecars an import hands its subtitle task now names that function. What an import places is
  unchanged.
