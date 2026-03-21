{ stdenv
, zig_0_15
, pkg-config
, wayland
, wayland-scanner
, wayland-protocols
, libxkbcommon
, ...
}:
let
  deps = stdenv.mkDerivation {
    name = "mzterwm-packages";
    src = ./.;

    outputHashMode = "recursive";
    outputHash = "sha256-vPCwZGq6NpbrF5vQVizKUOogYnvJVOmbaORysrGsxs8=";
    preferLocalBuild = true;

    nativeBuildInputs = [ zig_0_15 ];

    dontConfigure = true;

    env.ZIG_GLOBAL_CACHE_DIR = "$TMPDIR/zig-cache";

    buildPhase = ''
      zig build --fetch=all
    '';

    installPhase = ''
      mv "$ZIG_GLOBAL_CACHE_DIR/p" $out
    '';
  };
in
stdenv.mkDerivation {
  name = "mzterwm";
  src = ./.;

  nativeBuildInputs = [
    zig_0_15
    pkg-config
  ];

  buildInputs = [
    wayland
    wayland-scanner
    wayland-protocols
    libxkbcommon
  ];

  preBuild = ''
    ln -sf "${deps}" "$ZIG_GLOBAL_CACHE_DIR/p"
  '';
}

