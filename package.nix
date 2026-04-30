{ stdenv
, zig_0_16
, pkg-config
, wayland
, wayland-scanner
, wayland-protocols
, libxkbcommon
, ...
}:
let
  # We can't use zig_0_16.fetchDeps here, because that doesn't allow us to pass `--fetch=all`
  deps = stdenv.mkDerivation {
    name = "mzterwm-packages";
    src = ./.;

    outputHashMode = "recursive";
    outputHash = "sha256-+SJvVBiaK5gf6M4rCuGagl/DreEqCt5yIzYkBC45HbQ=";
    preferLocalBuild = true;

    nativeBuildInputs = [ zig_0_16 ];

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
    zig_0_16
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

