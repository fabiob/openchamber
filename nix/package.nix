{
  lib,
  stdenv,
  makeWrapper,
  bun,
  nodejs,
  git,
  openssh,
  python3,
  cloudflared,
  less,
  bash,
  coreutils,
  gnutar,
  bzip2,
  opencodeCli,
  self,
  version,
}:

let
  # Runtime PATH parity with the Docker image (Dockerfile lines 29-58):
  # the server spawns opencode, git, ssh, python3, and cloudflared. opencode
  # comes from upstream's flake, pinned to the 2.x version OpenChamber
  # requires (nixpkgs' opencode package is the older 1.x line).
  runtimePath = lib.makeBinPath [
    bun
    nodejs
    git
    openssh
    python3
    cloudflared
    less
    bash
    coreutils
    # tar + bzip2: the Docker recipe installs them for local dictation
    # model extraction (a .tar.bz2 unpacked via tar, #2887).
    gnutar
    bzip2
    opencodeCli
  ];

  src = lib.cleanSourceWith {
    src = self;
    filter =
      path: _type:
      let
        name = baseNameOf (toString path);
      in
      !lib.elem name [
        "node_modules"
        "dist"
        ".tmp"
        ".turbo"
        ".vite"
        ".direnv"
        ".envrc"
        "result"
      ];
  };

  # Fixed-output derivation holding bun's dependency cache for the whole
  # workspace. Only fetched content goes in here: tarballs are
  # integrity-pinned by bun.lock, so one baked hash is valid on every
  # machine and architecture. The warm install fetches every platform
  # variant we distribute for (linux + darwin): bun.lock records all
  # variants, and the offline install in bunDeps below silently skips
  # uncached optionals, so a cache warmed on linux must not starve a darwin
  # install.
  bunCache = stdenv.mkDerivation {
    pname = "openchamber-bun-cache";
    inherit version src;

    nativeBuildInputs = [ bun ];

    configurePhase = ":";
    buildPhase = ''
      export HOME="$PWD/.bun-home"
      mkdir -p "$HOME"
      export BUN_INSTALL_CACHE_DIR="$PWD/bun-cache"
      bun install --frozen-lockfile --ignore-scripts --os=linux --os=darwin --cpu='*' --libc='*'
    '';
    installPhase = ''
      # Phases run in the same build directory, in separate shells, so the
      # cache path is spelled out here instead of exported above.
      mkdir -p "$out"
      cp -a "$PWD/bun-cache" "$out/cache"
      # bun writes the cache's index symlinks
      # (cache/<name>/<version> → cache/<name>@<version>@@@1, scoped ones
      # under cache/@scope/) with ABSOLUTE targets pointing at the
      # install-time cache location. On linux that location is the fixed
      # /build, so the hash reproduces; on darwin the sandbox build
      # directory is randomized per run, which made this FOD hash
      # differently on every run. Rewrite each target relative to the
      # link's own directory — the target dir is always the link dir's
      # parent — so the content depends only on the fetched packages.
      find "$out/cache" -type l | while read -r link; do
        target=$(readlink "$link")
        case "$target" in
          */bun-cache/*) ;;
          *) continue ;;
        esac
        # The target dir is always the link dir's parent, so the relative
        # form is ../ plus the target's last path segment.
        ln -sfn "../$(basename "$target")" "$link"
      done
      echo "[bun-cache] absolute-target symlinks remaining: $(find "$out/cache" -type l -lname '/*' | wc -l | tr -d ' ')"
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    # The baked hashes live in one data file (nix/hashes.json), keyed per
    # system, so the automated bake PR touches a single file.
    outputHash =
      (builtins.fromJSON (builtins.readFile ./hashes.json)).bunCache.${stdenv.hostPlatform.system};

    # The cache is data for the install below; keep bun's files
    # byte-identical to what bun wrote.
    dontFixup = true;
  };

  # Normal (input-addressed) install of node_modules from the warmed cache.
  # Deliberately not a fixed-output derivation: bun install is not
  # reproducible across machines, so hashing its output can only produce
  # machine-relative hashes (CI runners baked five different node_modules
  # hashes from near-identical inputs, and every hash but the baking
  # runner's broke someone's build). The dependency set stays pinned twice:
  # integrity hashes in bun.lock, and the bunCache FOD above. The Nix
  # sandbox has no network, so nothing outside the warmed cache can enter
  # the install. Mirrors the Dockerfile deps stage: bun install
  # --frozen-lockfile --ignore-scripts. Patches from package.json
  # patchedDependencies are applied by bun itself; native builds are
  # skipped, matching Docker.
  bunDeps = stdenv.mkDerivation {
    pname = "openchamber-bun-deps";
    inherit version src;

    nativeBuildInputs = [ bun ];

    configurePhase = ":";
    buildPhase = ''
      export HOME="$PWD/.bun-home"
      mkdir -p "$HOME"
      export BUN_INSTALL_CACHE_DIR="$PWD/bun-cache"
      mkdir -p "$BUN_INSTALL_CACHE_DIR"
      cp -a "${bunCache}/cache/." "$BUN_INSTALL_CACHE_DIR/"
      chmod -R u+w "$BUN_INSTALL_CACHE_DIR"
      bun install --frozen-lockfile --ignore-scripts --offline
    '';
    installPhase = ''
      mkdir -p "$out"
      cp -a node_modules "$out/node_modules"
      find packages -maxdepth 2 -type d -name node_modules | while read -r dir; do
        mkdir -p "$out/$(dirname "$dir")"
        cp -a "$dir" "$out/$dir"
      done
    '';

    # Keep node_modules byte-identical to what bun produced (Docker parity):
    # no shebang rewriting, no patchelf, no symlink checks. Workspace .bin
    # symlinks only resolve once this is overlaid on the full source tree.
    dontFixup = true;
  };

  # Shared build: deps + sdk/web build + the runtime layout that both the
  # server CLI and the desktop app consume.
  openchamberCore = stdenv.mkDerivation {
    pname = "openchamber-core";
    inherit version src;

    nativeBuildInputs = [
      bun
      nodejs
    ];

    configurePhase = ''
      cp -a "${bunDeps}"/. .
      chmod -R u+w .
      # The build sandbox has no /usr/bin/env, so point .bin scripts at the
      # store node/bun before running the build.
      patchShebangs node_modules
      for dir in packages/*/node_modules; do
        [ -d "$dir" ] && patchShebangs "$dir"
      done
    '';

    buildPhase = ''
      # Same two commands as the Dockerfile builder stage. The server imports
      # @openchamber/sdk at runtime, so its dist output must exist.
      bun run --cwd packages/sdk build
      bun run build:web
    '';

    installPhase = ''
      appRoot="$out/lib/openchamber"
      mkdir -p "$appRoot/packages/web" "$appRoot/packages/sdk"

      # Runtime layout copied from the Dockerfile runtime stage.
      cp package.json "$appRoot/package.json"
      cp -a node_modules "$appRoot/node_modules"
      if [ -d packages/web/node_modules ]; then
        cp -a packages/web/node_modules "$appRoot/packages/web/node_modules"
      fi
      cp packages/web/package.json "$appRoot/packages/web/package.json"
      cp -a packages/web/bin "$appRoot/packages/web/bin"
      cp -a packages/web/server "$appRoot/packages/web/server"
      cp -a packages/web/dist "$appRoot/packages/web/dist"
      cp packages/sdk/package.json "$appRoot/packages/sdk/package.json"
      cp -a packages/sdk/dist "$appRoot/packages/sdk/dist"
    '';

    passthru = {
      inherit bunDeps src;
    };

    # node_modules must stay pristine (Docker parity); fixup hooks only
    # rewrite and reject things here.
    dontFixup = true;
  };
in
stdenv.mkDerivation {
  pname = "openchamber";
  inherit version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p "$out/bin"
    makeWrapper "${bun}/bin/bun" "$out/bin/openchamber" \
      --run "cd ${openchamberCore}/lib/openchamber" \
      --add-flags "packages/web/bin/cli.js" \
      --prefix PATH : "${runtimePath}" \
      --set NODE_ENV production \
      --set LANG C.UTF-8
  '';

  passthru = {
    inherit bunDeps bunCache src;
    core = openchamberCore;
  };

  meta = {
    description = "Web UI and server for OpenCode sessions";
    homepage = "https://github.com/openchamber/openchamber";
    license = lib.licenses.mit;
    mainProgram = "openchamber";
    # Claims follow the CI build matrix (nix-eval/nix-build workflows): a
    # platform stays listed while its runner builds the server green. The
    # desktop (nix/gui.nix) is verified on x86_64-linux only.
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
