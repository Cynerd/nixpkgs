{ lib, stdenv, fetchurl, fetchpatch2, openssl, python, zlib, libuv, http-parser, bash
, pkg-config, which, buildPackages
# for `.pkgs` attribute
, callPackage
# Updater dependencies
, writeScript, coreutils, gnugrep, jq, curl, common-updater-scripts, nix, runtimeShell
, gnupg
, darwin, xcbuild
, icu
, installShellFiles
}:

{ enableNpm ? true, version, sha256, patches ? [] } @args:

let
  inherit (darwin.apple_sdk.frameworks) CoreServices ApplicationServices;

  isCross = stdenv.hostPlatform != stdenv.buildPlatform;

  majorVersion = lib.versions.major version;
  minorVersion = lib.versions.minor version;

  pname = if enableNpm then "nodejs" else "nodejs-slim";

  useSharedHttpParser = !stdenv.isDarwin && lib.versionOlder "${majorVersion}.${minorVersion}" "11.4";

  sharedLibDeps = { inherit openssl zlib libuv; } // (lib.optionalAttrs useSharedHttpParser { inherit http-parser; });

  sharedConfigureFlags = lib.concatMap (name: [
    "--shared-${name}"
    "--shared-${name}-libpath=${lib.getLib sharedLibDeps.${name}}/lib"
    /** Closure notes: we explicitly avoid specifying --shared-*-includes,
     *  as that would put the paths into bin/nodejs.
     *  Including pkg-config in build inputs would also have the same effect!
     */
  ]) (builtins.attrNames sharedLibDeps) ++ [
    "--with-intl=system-icu"
    "--openssl-use-def-ca-store"
  ];

  copyLibHeaders =
    map
      (name: "${lib.getDev sharedLibDeps.${name}}/include/*")
      (builtins.attrNames sharedLibDeps);

  extraConfigFlags = lib.optionals (!enableNpm) [ "--without-npm" ];
  self = stdenv.mkDerivation {
    inherit pname version;

    src = fetchurl {
      url = "https://nodejs.org/dist/v${version}/node-v${version}.tar.xz";
      inherit sha256;
    };

    strictDeps = true;

    env = lib.optionalAttrs (stdenv.isDarwin && stdenv.isx86_64) {
      # Make sure libc++ uses `posix_memalign` instead of `aligned_alloc` on x86_64-darwin.
      # Otherwise, nodejs would require the 11.0 SDK and macOS 10.15+.
      NIX_CFLAGS_COMPILE = "-D__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__=101300";
    };

    # NB: technically, we do not need bash in build inputs since all scripts are
    # wrappers over the corresponding JS scripts. There are some packages though
    # that use bash wrappers, e.g. polaris-web.
    buildInputs = lib.optionals stdenv.isDarwin [ CoreServices ApplicationServices ]
      ++ [ zlib libuv openssl http-parser icu bash ];

    nativeBuildInputs = [ installShellFiles pkg-config python which ]
      ++ lib.optionals stdenv.isDarwin [ xcbuild ];

    outputs = [ "out" "libv8" ];
    setOutputFlags = false;
    moveToDev = false;

    configureFlags = let
      inherit (stdenv.hostPlatform) gcc isAarch32;
    in sharedConfigureFlags ++ lib.optionals (lib.versionOlder version "19") [
      "--without-dtrace"
    ] ++ (lib.optionals isCross [
      "--cross-compiling"
      "--dest-cpu=${let platform = stdenv.hostPlatform; in
                    if      platform.isAarch32 then "arm"
                    else if platform.isAarch64 then "arm64"
                    else if platform.isMips32 && platform.isLittleEndian then "mipsel"
                    else if platform.isMips32 && !platform.isLittleEndian then "mips"
                    else if platform.isMips64 && platform.isLittleEndian then "mips64el"
                    else if platform.isPower && platform.is32bit then "ppc"
                    else if platform.isPower && platform.is64bit then "ppc64"
                    else if platform.isx86_64 then "x86_64"
                    else if platform.isx86_32 then "x86"
                    else if platform.isS390 && platform.is64bit then "s390x"
                    else if platform.isRiscV && platform.is64bit then "riscv64"
                    else throw "unsupported cpu ${stdenv.hostPlatform.uname.processor}"}"
    ]) ++ (lib.optionals (isCross && isAarch32 && lib.hasAttr "fpu" gcc) [
      "--with-arm-fpu=${gcc.fpu}"
    ]) ++ (lib.optionals (isCross && isAarch32 && lib.hasAttr "float-abi" gcc) [
      "--with-arm-float-abi=${gcc.float-abi}"
    ]) ++ extraConfigFlags;

    configurePlatforms = [];

    dontDisableStatic = true;

    configureScript = writeScript "nodejs-configure" ''
      export CC_host="$CC" CXX_host="$CXX"
      exec ${python.executable} configure.py "$@"
    '';

    enableParallelBuilding = true;

    # Don't allow enabling content addressed conversion as `nodejs`
    # checksums it's image before conversion happens and image loading
    # breaks:
    #   $ nix build -f. nodejs --arg config '{ contentAddressedByDefault = true; }'
    #   $ ./result/bin/node
    #   Check failed: VerifyChecksum(blob).
    __contentAddressed = false;

    passthru.interpreterName = "nodejs";

    passthru.pkgs = callPackage ../../node-packages/default.nix {
      nodejs = self;
    };

    setupHook = ./setup-hook.sh;

    pos = builtins.unsafeGetAttrPos "version" args;

    patches = patches ++ [
      (fetchpatch2 {
        name = "add-qemu-wrapper-support.patch";
        url = "https://github.com/buildroot/buildroot/raw/ecf060a2ff93626fb5fbe1c52b8d42b6ee0fbb5b/package/nodejs/nodejs-src/0001-add-qemu-wrapper-support.patch";
        hash = "sha256-c6LY2c4JLuUwSIMvX/vbuUKPsDy0Uk/knW0Xnb4O6RY=";
      })
    ];

    postPatch = ''
      sed -i "s%@MAYBE_WRAPPER@%'<(PRODUCT_DIR)/v8-wrapper',%g" node.gyp
      sed -i "s%@MAYBE_WRAPPER@%'<(PRODUCT_DIR)/v8-wrapper',%g" tools/v8_gypfiles/v8.gyp
      mkdir -p out/Release
      cat > out/Release/v8-wrapper << "EOF"
      #!${buildPackages.bash}/bin/sh
      ${stdenv.hostPlatform.emulator buildPackages} "$@"
      EOF
      chmod +x out/Release/v8-wrapper
    '';

    doCheck = lib.versionAtLeast version "16"; # some tests fail on v14

    # Some dependencies required for tools/doc/node_modules (and therefore
    # test-addons, jstest and others) target are not included in the tarball.
    # Run test targets that do not require network access.
    checkTarget = lib.concatStringsSep " " [
      "build-js-native-api-tests"
      "build-node-api-tests"
      "tooltest"
      "cctest"
      "test-ci-js"
    ];

    checkFlags = [
      # Do not create __pycache__ when running tests.
      "PYTHONDONTWRITEBYTECODE=1"
      "FLAKY_TESTS=skip"
      # Skip some tests that are not passing in this context
      "CI_SKIP_TESTS=test-setproctitle,test-tls-cli-max-version-1.3,test-tls-client-auth,test-child-process-exec-env,test-fs-write-stream-eagain,test-tls-sni-option,test-https-foafssl,test-child-process-uid-gid,test-process-euid-egid,test-process-initgroups,test-process-uid-gid,test-process-setgroups"
    ];

    postInstall = ''
      HOST_PATH=$out/bin patchShebangs --host $out

      ${lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
        $out/bin/${self.meta.mainProgram} --completion-bash > ${self.meta.mainProgram}.bash
        installShellCompletion ${self.meta.mainProgram}.bash
      ''}

      ${lib.optionalString (enableNpm) ''
        mkdir -p $out/share/bash-completion/completions
        ln -s $out/lib/node_modules/npm/lib/utils/completion.sh \
          $out/share/bash-completion/completions/npm
        for dir in "$out/lib/node_modules/npm/man/"*; do
          mkdir -p $out/share/man/$(basename "$dir")
          for page in "$dir"/*; do
            ln -rs $page $out/share/man/$(basename "$dir")
          done
        done
      ''}

      # install the missing headers for node-gyp
      cp -r ${lib.concatStringsSep " " copyLibHeaders} $out/include/node

      # assemble a static v8 library and put it in the 'libv8' output
      mkdir -p $libv8/lib
      pushd out/Release/obj.target
      find . -path "./torque_*/**/*.o" -or -path "./v8*/**/*.o" | sort -u >files
      ${if stdenv.buildPlatform.isGnu then ''
        $AR -cqs $libv8/lib/libv8.a @files
      '' else ''
        # llvm-ar supports response files, so take advantage of it if it’s available.
        if [ "$(basename $(readlink -f $(command -v ar)))" = "llvm-ar" ]; then
          $AR -cqs $libv8/lib/libv8.a @files
        else
          cat files | while read -r file; do
            $AR -cqS $libv8/lib/libv8.a $file
          done
        fi
      ''}
      popd

      # copy v8 headers
      cp -r deps/v8/include $libv8/

      # create a pkgconfig file for v8
      major=$(grep V8_MAJOR_VERSION deps/v8/include/v8-version.h | cut -d ' ' -f 3)
      minor=$(grep V8_MINOR_VERSION deps/v8/include/v8-version.h | cut -d ' ' -f 3)
      patch=$(grep V8_PATCH_LEVEL deps/v8/include/v8-version.h | cut -d ' ' -f 3)
      mkdir -p $libv8/lib/pkgconfig
      cat > $libv8/lib/pkgconfig/v8.pc << EOF
      Name: v8
      Description: V8 JavaScript Engine
      Version: $major.$minor.$patch
      Libs: -L$libv8/lib -lv8 -pthread -licui18n -licuuc
      Cflags: -I$libv8/include
      EOF
    '';

    passthru.updateScript = import ./update.nix {
      inherit writeScript coreutils gnugrep jq curl common-updater-scripts gnupg nix runtimeShell;
      inherit lib;
      inherit majorVersion;
    };

    meta = with lib; {
      description = "Event-driven I/O framework for the V8 JavaScript engine";
      homepage = "https://nodejs.org";
      changelog = "https://github.com/nodejs/node/releases/tag/v${version}";
      license = licenses.mit;
      maintainers = with maintainers; [ goibhniu aduh95 ];
      platforms = platforms.linux ++ platforms.darwin;
      mainProgram = "node";
      knownVulnerabilities = optional (versionOlder version "18") "This NodeJS release has reached its end of life. See https://nodejs.org/en/about/releases/.";

      # Node.js build system does not have separate host and target OS
      # configurations (architectures are defined as host_arch and target_arch,
      # but there is no such thing as host_os and target_os).
      #
      # We may be missing something here, but it doesn’t look like it is
      # possible to cross-compile between different operating systems.
      broken = stdenv.buildPlatform.parsed.kernel.name != stdenv.hostPlatform.parsed.kernel.name;
    };

    passthru.python = python; # to ensure nodeEnv uses the same version
  };
in self
