{
  description = "Development environment for the Koka compiler";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # stack.yaml pins resolver lts-24.x which is GHC 9.10.x
        hpkgs = pkgs.haskell.packages.ghc910;

        # Tools needed to build the compiler itself (Haskell side).
        haskellTools = [
          hpkgs.ghc
          pkgs.cabal-install
          pkgs.stack
          hpkgs.alex # listed under build-tools in package.yaml
          pkgs.git   # cabal fetches the forked lsp package via source-repository-package
          pkgs.pkg-config
          pkgs.zlib
        ];

        # Tools the koka compiler invokes at *run* time to compile its output.
        backendTools = [
          pkgs.clang      # C backend (default target); koka looks for clang/gcc/cc on PATH
          pkgs.cmake      # used by kklib/mimalloc and util/bundle
          pkgs.nodejs     # --target=js / jsnode
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          packages = haskellTools ++ backendTools;

          # koka passes -mtune=native to the C compiler for optimized builds;
          # nix's cc-wrapper strips it (with a warning) unless this is unset.
          NIX_ENFORCE_NO_NATIVE = 0;

          shellHook = ''
            echo "koka dev shell: $(ghc --numeric-version | sed 's/^/ghc /'), $(cabal --numeric-version | sed 's/^/cabal /'), $(clang --version | head -1)"
            echo "  build:  cabal update && cabal build exe:koka"
            echo "  run:    cabal run exe:koka -- <file.kk>"
          '';
        };

        # Optional shell with Mono's `csc` for the legacy --target=cs backend.
        devShells.csharp = pkgs.mkShell {
          packages = haskellTools ++ backendTools ++ [ pkgs.mono ];
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
