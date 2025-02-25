{
  lib,
  bazel_6,
  bazel-gazelle,
  buildBazelPackage,
  fetchFromGitHub,
  applyPatches,
  stdenv,
  cacert,
  cargo,
  rustc,
  rustPlatform,
  cmake,
  gn,
  go,
  jdk,
  ninja,
  patchelf,
  python3,
  linuxHeaders,
  nixosTests,

  # v8 (upstream default), wavm, wamr, wasmtime, disabled
  wasmRuntime ? "wamr",
}:

let
  srcVer = {
    # We need the commit hash, since Bazel stamps the build with it.
    # However, the version string is more useful for end-users.
    # These are contained in a attrset of their own to make it obvious that
    # people should update both.
    version = "1.32.3";
    rev = "58bd599ebd5918d4d005de60954fcd2cb00abd95";
    hash = "sha256-5HpxcsAPoyVOJ3Aem+ZjSLa8Zu6s76iCMiWJbp8RjHc=";
  };

  # these need to be updated for any changes to fetchAttrs
  depsHash =
    {
      x86_64-linux = "sha256-YFXNatolLM9DdwkMnc9SWsa6Z6/aGzqLmo/zKE7OFy0=";
      aarch64-linux = "sha256-AjG1OBjPjiSwWCmIJgHevSQHx8+rzRgmLsw3JwwD0hk=";
    }
    .${stdenv.system} or (throw "unsupported system ${stdenv.system}");

in
buildBazelPackage rec {
  pname = "envoy";
  inherit (srcVer) version;
  bazel = bazel_6;

  src = applyPatches {
    src = fetchFromGitHub {
      owner = "envoyproxy";
      repo = "envoy";
      inherit (srcVer) hash rev;
    };
    patches = [
      # use system Python, not bazel-fetched binary Python
      ./0001-nixpkgs-use-system-Python.patch

      # use system Go, not bazel-fetched binary Go
      ./0002-nixpkgs-use-system-Go.patch

      # use system C/C++ tools
      ./0003-nixpkgs-use-system-C-C-toolchains.patch

      # patch boringssl to work with GCC 14
      # vendored patch from https://boringssl.googlesource.com/boringssl/+/c70190368c7040c37c1d655f0690bcde2b109a0d
      ./0004-nixpkgs-patch-boringssl-for-gcc14.patch

      # update rust rules to work with rustc v1.83
      # cherry-pick of https://github.com/envoyproxy/envoy/commit/019f589da2cc8da7673edd077478a100b4d99436
      # drop with v1.33.x
      ./0005-deps-Bump-rules_rust-0.54.1-37056.patch

      # patch gcc flags to work with GCC 14
      # (silences erroneus -Werror=maybe-uninitialized and others)
      # cherry-pick of https://github.com/envoyproxy/envoy/commit/448e4e14f4f188687580362a861ae4a0dbb5b1fb
      # drop with v1.33.x
      ./0006-gcc-warnings.patch

      # Remove "-Werror" from protobuf build
      # This is fixed in protobuf v28 and later:
      # https://github.com/protocolbuffers/protobuf/commit/f5a1b178ad52c3e64da40caceaa4ca9e51045cb4
      # drop with v1.33.x
      ./0007-protobuf-remove-Werror.patch
    ];
    postPatch = ''
      chmod -R +w .
      rm ./.bazelversion
      echo ${srcVer.rev} > ./SOURCE_VERSION
    '';
  };

  postPatch = ''
    sed -i 's,#!/usr/bin/env python3,#!${python3}/bin/python,' bazel/foreign_cc/luajit.patch
    sed -i '/javabase=/d' .bazelrc
    sed -i '/"-Werror"/d' bazel/envoy_internal.bzl

    mkdir -p bazel/nix/
    substitute ${./bazel_nix.BUILD.bazel} bazel/nix/BUILD.bazel \
      --subst-var-by bash "$(type -p bash)"
    ln -sf "${cargo}/bin/cargo" bazel/nix/cargo
    ln -sf "${rustc}/bin/rustc" bazel/nix/rustc
    ln -sf "${rustc}/bin/rustdoc" bazel/nix/rustdoc
    ln -sf "${rustPlatform.rustLibSrc}" bazel/nix/ruststd
    substituteInPlace bazel/dependency_imports.bzl \
      --replace-fail 'crate_universe_dependencies()' 'crate_universe_dependencies(rust_toolchain_cargo_template="@@//bazel/nix:cargo", rust_toolchain_rustc_template="@@//bazel/nix:rustc")' \
      --replace-fail 'crates_repository(' 'crates_repository(rust_toolchain_cargo_template="@@//bazel/nix:cargo", rust_toolchain_rustc_template="@@//bazel/nix:rustc",'

    substitute ${./rules_rust_extra.patch} bazel/nix/rules_rust_extra.patch \
      --subst-var-by bash "$(type -p bash)"
    cat bazel/nix/rules_rust_extra.patch bazel/rules_rust.patch > bazel/nix/rules_rust.patch
    mv bazel/nix/rules_rust.patch bazel/rules_rust.patch
  '';

  nativeBuildInputs = [
    cmake
    python3
    gn
    go
    jdk
    ninja
    patchelf
    cacert
  ];

  buildInputs = [ linuxHeaders ];

  fetchAttrs = {
    sha256 = depsHash;
    env.CARGO_BAZEL_REPIN = true;
    dontUseCmakeConfigure = true;
    dontUseGnConfigure = true;
    postPatch = ''
      ${postPatch}

      substituteInPlace bazel/dependency_imports.bzl \
        --replace-fail 'crate_universe_dependencies(' 'crate_universe_dependencies(bootstrap=True, ' \
        --replace-fail 'crates_repository(' 'crates_repository(generator="@@cargo_bazel_bootstrap//:cargo-bazel", '
    '';
    preInstall = ''
      # Strip out the path to the build location (by deleting the comment line).
      find $bazelOut/external -name requirements.bzl | while read requirements; do
        sed -i '/# Generated from /d' "$requirements"
      done

      # Remove references to paths in the Nix store.
      sed -i \
        -e 's,${python3},__NIXPYTHON__,' \
        -e 's,${stdenv.shellPackage},__NIXSHELL__,' \
        $bazelOut/external/com_github_luajit_luajit/build.py \
        $bazelOut/external/local_config_sh/BUILD \
        $bazelOut/external/*_pip3/BUILD.bazel

      rm -r $bazelOut/external/go_sdk
      rm -r $bazelOut/external/local_jdk
      rm -r $bazelOut/external/bazel_gazelle_go_repository_tools/bin

      # Remove compiled python
      find $bazelOut -name '*.pyc' -delete

      # Remove Unix timestamps from go cache.
      rm -rf $bazelOut/external/bazel_gazelle_go_repository_cache/{gocache,pkg/mod/cache,pkg/sumdb}

      # fix tcmalloc failure https://github.com/envoyproxy/envoy/issues/30838
      sed -i '/TCMALLOC_GCC_FLAGS = \[/a"-Wno-changes-meaning",' $bazelOut/external/com_github_google_tcmalloc/tcmalloc/copts.bzl

      # Install repinned rules_rust lockfile
      cp source/extensions/dynamic_modules/sdk/rust/Cargo.Bazel.lock $bazelOut/external/Cargo.Bazel.lock

      # Don't save cargo_bazel_bootstrap or the crate index cache
      rm -rf $bazelOut/external/cargo_bazel_bootstrap $bazelOut/external/dynamic_modules_rust_sdk_crate_index/.cargo_home $bazelOut/external/dynamic_modules_rust_sdk_crate_index/splicing-output
    '';
  };
  buildAttrs = {
    dontUseCmakeConfigure = true;
    dontUseGnConfigure = true;
    dontUseNinjaInstall = true;
    preConfigure = ''
      # Make executables work, for the most part.
      find $bazelOut/external -type f -executable | while read execbin; do
        file "$execbin" | grep -q ': ELF .*, dynamically linked,' || continue
        patchelf \
          --set-interpreter $(cat ${stdenv.cc}/nix-support/dynamic-linker) \
          "$execbin" || echo "$execbin"
      done

      ln -s ${bazel-gazelle}/bin $bazelOut/external/bazel_gazelle_go_repository_tools/bin

      sed -i 's,#!/usr/bin/env bash,#!${stdenv.shell},' $bazelOut/external/rules_foreign_cc/foreign_cc/private/framework/toolchains/linux_commands.bzl

      # Add paths to Nix store back.
      sed -i \
        -e 's,__NIXPYTHON__,${python3},' \
        -e 's,__NIXSHELL__,${stdenv.shellPackage},' \
        $bazelOut/external/com_github_luajit_luajit/build.py \
        $bazelOut/external/local_config_sh/BUILD \
        $bazelOut/external/*_pip3/BUILD.bazel

      # Install repinned rules_rust lockfile
      cp $bazelOut/external/Cargo.Bazel.lock source/extensions/dynamic_modules/sdk/rust/Cargo.Bazel.lock
    '';
    installPhase = ''
      install -Dm0755 bazel-bin/source/exe/envoy-static $out/bin/envoy
    '';
  };

  removeRulesCC = false;
  removeLocalConfigCc = true;
  removeLocal = false;
  bazelTargets = [ "//source/exe:envoy-static" ];
  bazelBuildFlags =
    [
      "-c opt"
      "--spawn_strategy=standalone"
      "--noexperimental_strict_action_env"
      "--cxxopt=-Wno-error"
      "--linkopt=-Wl,-z,noexecstack"
      "--config=gcc"
      "--verbose_failures"

      # Force use of system Java.
      "--extra_toolchains=@local_jdk//:all"
      "--java_runtime_version=local_jdk"
      "--tool_java_runtime_version=local_jdk"

      # Force use of system Rust.
      "--extra_toolchains=//bazel/nix:rust_nix_aarch64,//bazel/nix:rust_nix_x86_64"

      # undefined reference to 'grpc_core::*Metadata*::*Memento*
      #
      # During linking of the final binary, we see undefined references to grpc_core related symbols.
      # The missing symbols would be instantiations of a template class from https://github.com/grpc/grpc/blob/v1.59.4/src/core/lib/transport/metadata_batch.h
      # "ParseMemento" and "MementoToValue" are only implemented for some types
      # and appear unused and unimplemented for the undefined cases reported by the linker.
      "--linkopt=-Wl,--unresolved-symbols=ignore-in-object-files"

      "--define=wasm=${wasmRuntime}"
    ]
    ++ (lib.optionals stdenv.hostPlatform.isAarch64 [
      # external/com_github_google_tcmalloc/tcmalloc/internal/percpu_tcmalloc.h:611:9: error: expected ':' or '::' before '[' token
      #   611 |       : [end_ptr] "=&r"(end_ptr), [cpu_id] "=&r"(cpu_id),
      #       |         ^
      "--define=tcmalloc=disabled"
    ]);

  bazelFetchFlags = [
    "--define=wasm=${wasmRuntime}"

    # Force use of system Rust.
    "--extra_toolchains=//bazel/nix:rust_nix_aarch64,//bazel/nix:rust_nix_x86_64"

    # https://github.com/bazelbuild/rules_go/issues/3844
    "--repo_env=GOPROXY=https://proxy.golang.org,direct"
    "--repo_env=GOSUMDB=sum.golang.org"
  ];

  requiredSystemFeatures = [ "big-parallel" ];

  passthru.tests = {
    envoy = nixosTests.envoy;
    # tested as a core component of Pomerium
    pomerium = nixosTests.pomerium;
  };

  meta = with lib; {
    homepage = "https://envoyproxy.io";
    changelog = "https://github.com/envoyproxy/envoy/releases/tag/v${version}";
    description = "Cloud-native edge and service proxy";
    mainProgram = "envoy";
    license = licenses.asl20;
    maintainers = with maintainers; [ lukegb ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
