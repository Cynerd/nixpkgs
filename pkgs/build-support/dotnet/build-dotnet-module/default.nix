{ lib
, stdenvNoCC
, callPackage
, writeShellScript
, srcOnly
, linkFarmFromDrvs
, symlinkJoin
, makeWrapper
, dotnetCorePackages
, mkNugetSource
, mkNugetDeps
, nuget-to-nix
, cacert
, coreutils
, runtimeShellPackage
}:

{ name ? "${args.pname}-${args.version}"
, pname ? name
, enableParallelBuilding ? true
, doCheck ? false
  # Flags to pass to `makeWrapper`. This is done to avoid double wrapping.
, makeWrapperArgs ? [ ]

  # Flags to pass to `dotnet restore`.
, dotnetRestoreFlags ? [ ]
  # Flags to pass to `dotnet build`.
, dotnetBuildFlags ? [ ]
  # Flags to pass to `dotnet test`, if running tests is enabled.
, dotnetTestFlags ? [ ]
  # Flags to pass to `dotnet install`.
, dotnetInstallFlags ? [ ]
  # Flags to pass to `dotnet pack`.
, dotnetPackFlags ? [ ]
  # Flags to pass to dotnet in all phases.
, dotnetFlags ? [ ]

  # The path to publish the project to. When unset, the directory "$out/lib/$pname" is used.
, installPath ? null
  # The binaries that should get installed to `$out/bin`, relative to `$out/lib/$pname/`. These get wrapped accordingly.
  # Unfortunately, dotnet has no method for doing this automatically.
  # If unset, all executables in the projects root will get installed. This may cause bloat!
, executables ? null
  # Packs a project as a `nupkg`, and installs it to `$out/share`. If set to `true`, the derivation can be used as a dependency for another dotnet project by adding it to `projectReferences`.
, packNupkg ? false
  # The packages project file, which contains instructions on how to compile it. This can be an array of multiple project files as well.
, projectFile ? null
  # The NuGet dependency file. This locks all NuGet dependency versions, as otherwise they cannot be deterministically fetched.
  # This can be generated by running the `passthru.fetch-deps` script.
, nugetDeps ? null
  # A list of derivations containing nupkg packages for local project references.
  # Referenced derivations can be built with `buildDotnetModule` with `packNupkg=true` flag.
  # Since we are sharing them as nugets they must be added to csproj/fsproj files as `PackageReference` as well.
  # For example, your project has a local dependency:
  #     <ProjectReference Include="../foo/bar.fsproj" />
  # To enable discovery through `projectReferences` you would need to add a line:
  #     <ProjectReference Include="../foo/bar.fsproj" />
  #     <PackageReference Include="bar" Version="*" Condition=" '$(ContinuousIntegrationBuild)'=='true' "/>
, projectReferences ? [ ]
  # Libraries that need to be available at runtime should be passed through this.
  # These get wrapped into `LD_LIBRARY_PATH`.
, runtimeDeps ? [ ]
  # The dotnet runtime ID. If null, fetch-deps will gather dependencies for all
  # platforms in meta.platforms which are supported by the sdk.
, runtimeId ? null

  # Tests to disable. This gets passed to `dotnet test --filter "FullyQualifiedName!={}"`, to ensure compatibility with all frameworks.
  # See https://docs.microsoft.com/en-us/dotnet/core/tools/dotnet-test#filter-option-details for more details.
, disabledTests ? [ ]
  # The project file to run unit tests against. This is usually referenced in the regular project file, but sometimes it needs to be manually set.
  # It gets restored and build, but not installed. You may need to regenerate your nuget lockfile after setting this.
, testProjectFile ? ""

  # The type of build to perform. This is passed to `dotnet` with the `--configuration` flag. Possible values are `Release`, `Debug`, etc.
, buildType ? "Release"
  # If set to true, builds the application as a self-contained - removing the runtime dependency on dotnet
, selfContainedBuild ? false
  # Whether to use an alternative wrapper, that executes the application DLL using the dotnet runtime from the user environment. `dotnet-runtime` is provided as a default in case no .NET is installed
  # This is useful for .NET tools and applications that may need to run under different .NET runtimes
, useDotnetFromEnv ? false
  # Whether to explicitly enable UseAppHost when building. This is redundant if useDotnetFromEnv is enabledz
, useAppHost ? true
  # The dotnet SDK to use.
, dotnet-sdk ? dotnetCorePackages.sdk_6_0
  # The dotnet runtime to use.
, dotnet-runtime ? dotnetCorePackages.runtime_6_0
  # The dotnet SDK to run tests against. This can differentiate from the SDK compiled against.
, dotnet-test-sdk ? dotnet-sdk
, ...
} @ args:

let
  platforms =
    if args ? meta.platforms
    then lib.intersectLists args.meta.platforms dotnet-sdk.meta.platforms
    else dotnet-sdk.meta.platforms;

  inherit (callPackage ./hooks {
    inherit dotnet-sdk dotnet-test-sdk disabledTests nuget-source dotnet-runtime runtimeDeps buildType;
    runtimeId =
      if runtimeId != null
      then runtimeId
      else dotnetCorePackages.systemToDotnetRid stdenvNoCC.targetPlatform.system;
  }) dotnetConfigureHook dotnetBuildHook dotnetCheckHook dotnetInstallHook dotnetFixupHook;

  localDeps =
    if (projectReferences != [ ])
    then linkFarmFromDrvs "${name}-project-references" projectReferences
    else null;

  _nugetDeps =
    if (nugetDeps != null) then
      if lib.isDerivation nugetDeps
      then nugetDeps
      else mkNugetDeps {
        inherit name;
        nugetDeps = import nugetDeps;
        sourceFile = nugetDeps;
      }
    else throw "Defining the `nugetDeps` attribute is required, as to lock the NuGet dependencies. This file can be generated by running the `passthru.fetch-deps` script.";

  # contains the actual package dependencies
  dependenciesSource = mkNugetSource {
    name = "${name}-dependencies-source";
    description = "A Nuget source with the dependencies for ${name}";
    deps = [ _nugetDeps ] ++ lib.optional (localDeps != null) localDeps;
  };

  # this contains all the nuget packages that are implicitly referenced by the dotnet
  # build system. having them as separate deps allows us to avoid having to regenerate
  # a packages dependencies when the dotnet-sdk version changes
  sdkDeps = lib.lists.flatten [ dotnet-sdk.packages ];

  sdkSource = let
    version = dotnet-sdk.version or (lib.concatStringsSep "-" dotnet-sdk.versions);
  in mkNugetSource {
    name = "dotnet-sdk-${version}-source";
    deps = sdkDeps;
  };

  nuget-source = symlinkJoin {
    name = "${name}-nuget-source";
    paths = [ dependenciesSource sdkSource ];
  };

  nugetDepsFile = _nugetDeps.sourceFile;
in
stdenvNoCC.mkDerivation (args // {
  nativeBuildInputs = args.nativeBuildInputs or [ ] ++ [
    dotnetConfigureHook
    dotnetBuildHook
    dotnetCheckHook
    dotnetInstallHook
    dotnetFixupHook

    cacert
    makeWrapper
    dotnet-sdk
  ];

  makeWrapperArgs = args.makeWrapperArgs or [ ] ++ [
    "--prefix LD_LIBRARY_PATH : ${dotnet-sdk.icu}/lib"
  ];

  # Stripping breaks the executable
  dontStrip = args.dontStrip or true;

  # gappsWrapperArgs gets included when wrapping for dotnet, as to avoid double wrapping
  dontWrapGApps = args.dontWrapGApps or true;

  inherit selfContainedBuild useAppHost useDotnetFromEnv;

  passthru = {
    inherit nuget-source;

    fetch-deps =
      let
        flags = dotnetFlags ++ dotnetRestoreFlags;
        runtimeIds =
          if runtimeId != null
          then [ runtimeId ]
          else map (system: dotnetCorePackages.systemToDotnetRid system) platforms;
        defaultDepsFile =
          # Wire in the nugetDeps file such that running the script with no args
          # runs it agains the correct deps file by default.
          # Note that toString is necessary here as it results in the path at
          # eval time (i.e. to the file in your local Nixpkgs checkout) rather
          # than the Nix store path of the path after it's been imported.
          if lib.isPath nugetDepsFile && !lib.hasPrefix "${builtins.storeDir}/" (toString nugetDepsFile)
          then toString nugetDepsFile
          else ''$(mktemp -t "${pname}-deps-XXXXXX.nix")'';
      in
      writeShellScript "fetch-${pname}-deps" ''
        set -euo pipefail

        export PATH="${lib.makeBinPath [ coreutils runtimeShellPackage dotnet-sdk (nuget-to-nix.override { inherit dotnet-sdk; }) ]}"

        for arg in "$@"; do
            case "$arg" in
                --keep-sources|-k)
                    keepSources=1
                    shift
                    ;;
                --help|-h)
                    echo "usage: $0 [--keep-sources] [--help] <output path>"
                    echo "    <output path>   The path to write the lockfile to. A temporary file is used if this is not set"
                    echo "    --keep-sources  Dont remove temporary directories upon exit, useful for debugging"
                    echo "    --help          Show this help message"
                    exit
                    ;;
            esac
        done

        if [[ ''${TMPDIR:-} == /run/user/* ]]; then
           # /run/user is usually a tmpfs in RAM, which may be too small
           # to store all downloaded dotnet packages
           unset TMPDIR
        fi

        export tmp=$(mktemp -td "deps-${pname}-XXXXXX")
        HOME=$tmp/home

        exitTrap() {
            test -n "''${ranTrap-}" && return
            ranTrap=1

            if test -n "''${keepSources-}"; then
                echo -e "Path to the source: $tmp/src\nPath to the fake home: $tmp/home"
            else
                rm -rf "$tmp"
            fi

            # Since mktemp is used this will be empty if the script didnt succesfully complete
            if ! test -s "$depsFile"; then
              rm -rf "$depsFile"
            fi
        }

        trap exitTrap EXIT INT TERM

        dotnetRestore() {
            local -r project="''${1-}"
            local -r rid="$2"

            dotnet restore ''${project-} \
                -p:ContinuousIntegrationBuild=true \
                -p:Deterministic=true \
                --packages "$tmp/nuget_pkgs" \
                --runtime "$rid" \
                --no-cache \
                --force \
                ${lib.optionalString (!enableParallelBuilding) "--disable-parallel"} \
                ${lib.optionalString (flags != []) (toString flags)}
        }

        declare -a projectFiles=( ${toString (lib.toList projectFile)} )
        declare -a testProjectFiles=( ${toString (lib.toList testProjectFile)} )

        export DOTNET_NOLOGO=1
        export DOTNET_CLI_TELEMETRY_OPTOUT=1

        depsFile=$(realpath "''${1:-${defaultDepsFile}}")
        echo Will write lockfile to "$depsFile"
        mkdir -p "$tmp/nuget_pkgs"

        storeSrc="${srcOnly args}"
        src=$tmp/src
        cp -rT "$storeSrc" "$src"
        chmod -R +w "$src"

        cd "$src"
        echo "Restoring project..."

        ${dotnet-sdk}/bin/dotnet tool restore
        cp -r $HOME/.nuget/packages/* $tmp/nuget_pkgs || true

        for rid in "${lib.concatStringsSep "\" \"" runtimeIds}"; do
            (( ''${#projectFiles[@]} == 0 )) && dotnetRestore "" "$rid"

            for project in ''${projectFiles[@]-} ''${testProjectFiles[@]-}; do
                dotnetRestore "$project" "$rid"
            done
        done
        # Second copy, makes sure packages restored by ie. paket are included
        cp -r $HOME/.nuget/packages/* $tmp/nuget_pkgs || true

        echo "Succesfully restored project"

        echo "Writing lockfile..."

        excluded_sources="${lib.concatStringsSep " " sdkDeps}"
        for excluded_source in ''${excluded_sources[@]}; do
          ls "$excluded_source" >> "$tmp/excluded_list"
        done
        tmpFile="$tmp"/deps.nix
        echo -e "# This file was automatically generated by passthru.fetch-deps.\n# Please dont edit it manually, your changes might get overwritten!\n" > "$tmpFile"
        nuget-to-nix "$tmp/nuget_pkgs" "$tmp/excluded_list" >> "$tmpFile"
        mv "$tmpFile" "$depsFile"
        echo "Succesfully wrote lockfile to $depsFile"
      '';
  } // args.passthru or { };

  meta = (args.meta or { }) // { inherit platforms; };
}
  # ICU tries to unconditionally load files from /usr/share/icu on Darwin, which makes builds fail
  # in the sandbox, so disable ICU on Darwin. This, as far as I know, shouldn't cause any built packages
  # to behave differently, just the dotnet build tool.
  // lib.optionalAttrs stdenvNoCC.isDarwin { DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = 1; })
