{
  lib,
  stdenv,
  mkShell,
  zig,
  flakever,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "genesis-shell";
  inherit (flakever) version;

  src = lib.cleanSource ../../.;

  zigDeps = zig.fetchDeps {
    inherit (finalAttrs) src pname version;
    hash = "sha256-hETRKt9Ub9LH+wdIHF+b9SJEAbYf9sTgpt/xaH4dh0k=";
  };

  nativeBuildInputs = [
    zig
  ];

  postConfigure = ''
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  doCheck = true;

  passthru.shell = mkShell {
    name = "genesis-dev-shell";
    packages = [
      zig
    ];
  };
})
