# mzterwm

A window manager for [River](https://isaacfreund.com/software/river/) that aims to implement the
river-classic tag model, where all windows can be in many "workspaces" (tags) at once and we can
also view multiple of them at once.

## TODO

- [x] Focus layout (rivertile-like)
- [x] Gaps
- [x] Tags
- [x] Output management with ability to restore state after output reconnect
- [x] Config file
- [ ] Waybar plugin
- [x] IPC socket
- [x] Layer shell WM
- [x] Focusing Windows
- [ ] ~Multi-Seat~
    - mzterwm currently contains an untested and half-assed attempt at not exploding with multiple
      seats. Stuff like each seat having it's own focused window and such is entirely unimplemented
      and probably won't be implemented unless someone steps up.
- [ ] Have all these be well-tested
