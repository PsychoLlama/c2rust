{
  description = "Flake for c2rust";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      utils,
      fenix,
      ...
    }:
    utils.lib.eachDefaultSystem (
      system:
      let
        fenixToolchain =
          let
            toml = with builtins; (fromTOML (readFile ./rust-toolchain.toml)).toolchain;
          in
          (fenix.packages.${system}.fromToolchainName {
            name = toml.channel;
            sha256 = "sha256-uKdO6izw+PivrIfXdPq65XQtww3Va8pi/+c6SaeuW74";
          })."completeToolchain";

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ ];
          config = {
            allowUnfree = true;
          };
        };

        myLLVM = pkgs.llvmPackages;
        myStdenv = pkgs.clangStdenv;

        rustPlatform = pkgs.makeRustPlatform {
          cargo = fenixToolchain;
          rustc = fenixToolchain;
        };
        env = {
          CMAKE_LLVM_DIR = "${myLLVM.libllvm.dev}/lib/cmake/llvm";
          CMAKE_CLANG_DIR = "${myLLVM.libclang.dev}/lib/cmake/clang";
          LLVM_CONFIG_PATH = "${myLLVM.libllvm.dev}/bin/llvm-config";
          CLANG_PATH = "${myLLVM.clang}/bin/clang";
          TINYCBOR_DIR = "${pkgs.tinycbor}";
          NIX_ENFORCE_NO_NATIVE = 0; # Enable SSE instructions.
          # Enable nix in the c2rust test suite
          # This flag is used to tell the test scripts to look for
          # libraries under nix paths.
          C2RUST_USE_NIX = 1;
          RUST_SRC_PATH = "${fenixToolchain}/lib/rustlib/src/rust/library";
        };

        # Only pull the files cargo actually needs to build `-p c2rust` into
        # the store, so unrelated churn (docs, examples, tests, tooling, the
        # working tree, etc.) doesn't invalidate the build. Cargo loads the
        # entire workspace even for a single `-p` target, so every member
        # listed in the root `Cargo.toml` must be present — but nothing
        # outside those members is required.
        src =
          let
            fs = pkgs.lib.fileset;
          in
          fs.toSource {
            root = ./.;
            fileset = fs.unions [
              ./Cargo.toml
              ./Cargo.lock
              ./.cargo
              # Workspace members (see root Cargo.toml `members`).
              ./analysis/runtime
              ./c2rust
              ./c2rust-analyze
              ./c2rust-asm-casts
              ./c2rust-ast-builder
              ./c2rust-ast-exporter
              ./c2rust-ast-printer
              ./c2rust-bitfields
              ./c2rust-bitfields-derive
              ./c2rust-build-paths
              ./c2rust-macros
              ./c2rust-refactor
              ./c2rust-rust-tools
              ./c2rust-transpile
              ./dynamic_instrumentation
              ./pdg
            ];
          };
      in
      rec {
        packages = {
          default = rustPlatform.buildRustPackage (
            with pkgs;
            env
            // {
              pname = "c2rust";
              version = "0.20.0";
              inherit src;
              doCheck = false; # Can use checkFlags to disable specific tests

              # Build only the `c2rust` transpiler binary. The full workspace
              # includes the legacy `c2rust-refactor` crate, whose build script
              # execs `gen/process_ast.py` (shebang `#!/usr/bin/env -S uv run`);
              # `/usr/bin/env` is absent in the pure build sandbox, so that
              # crate fails to build. `c2rust` does not depend on it.
              cargoBuildFlags = [
                "-p"
                "c2rust"
              ];

              patches = [ ./nix-tinycbor-cmake.patch ];

              nativeBuildInputs = with pkgs; [
                pkg-config
                cmake
                uv
                (python3.withPackages (
                  python-pkgs: with python-pkgs; [
                    "bencode-python3"
                    cbor
                    colorlog
                    mako
                    pip
                    plumbum
                    psutil
                    pygments
                    typing
                    "scan-build"
                    pyyaml
                    toml
                  ]
                ))
                myStdenv.cc
                myLLVM.libclang
                myLLVM.clang
                myLLVM.llvm
                myLLVM.libllvm
              ];

              buildInputs = with pkgs; [
                curl.dev
                rustPlatform.bindgenHook
                myStdenv.cc
                myLLVM.libclang
                myLLVM.clang
                myLLVM.llvm
                myLLVM.libllvm
                tinycbor
                openssl
                zlib
                fenixToolchain
                z3.dev
              ];

              cargoLock = {
                lockFile = ./Cargo.lock;
              };
            }
          );
        };
        defaultPackage = packages.default;

        devShells = {
          # Include a fixed version of clang in the development environment for testing.
          default = pkgs.mkShell (
            env
            // {
              strictDeps = true;
              inputsFrom = [ packages.default ];
              buildInputs = [ ];
            }
          );
        };

        devShell = devShells.default;
      }
    );
}
