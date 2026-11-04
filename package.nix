{ stdenv
, zig_0_17
, pkg-config
, wayland
, wayland-scanner
, wayland-protocols
, libxkbcommon
, ...
}:
let
  pname = "mzterwm";
  version = "master";
  src = ./.;
  deps = zig_0_17.fetchDeps {
    inherit pname version src;
    fetchAll = true;
    hash = "sha256-cpWpBQ97iStk3ZHQytJogKxVrTpqbZiIEpryCIj/gkY=";
  };
  # We can't use zig_0_17.fetchDeps here, because that doesn't allow us to pass `--fetch=all`
  #deps = stdenv.mkDerivation {
  #  name = "mzterwm-packages";
  #  src = ./.;

  #  outputHashMode = "recursive";
  #  outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  #  preferLocalBuild = true;

  #  nativeBuildInputs = [ zig_0_17 ];

  #  dontConfigure = true;

  #  env.ZIG_GLOBAL_CACHE_DIR = "$TMPDIR/zig-cache";

  #  buildPhase = ''
  #    zig build --fetch=all
  #  '';

  #  installPhase = ''
  #    mv "$ZIG_GLOBAL_CACHE_DIR/p" $out
  #  '';
  #};
in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    zig_0_17
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

