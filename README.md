# mzterwm

A window manager for [River](https://isaacfreund.com/software/river/) that aims to implement the
river-classic tag model, where all windows can be in many "workspaces" (tags) at once and we can
also view multiple of them at once.

## TODO

- [x] Focus layout (rivertile-like)
- [x] Gaps
- [x] Tags
- [ ] Output management with ability to restore state after output reconnect
- [x] Config file
- [ ] Waybar plugin
- [ ] IPC socket
- [ ] Layer shell WM
- [x] Focusing Windows
- [ ] ~Multi-Seat~
    - mzterwm currently contains a tested and half-assed attempt at not exploding with multiple
      seats. Stuff like each seat having it's own focused window and such is entirely unimplemented
      and probably won't be implemented unless someone steps up.
