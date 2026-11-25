{
  # Devshell nach dem Muster von project-flake (`nix develop ./dev`, direnv: .envrc). Eine eigene
  # Flake, damit die Flake im Wurzelordner ohne nixpkgs auskommt (siehe dort). Gebaut und
  # veröffentlicht wird weiter über die Workflows in .github/ (Flutter, Gradle und das
  # Android-SDK laden beim Bauen aus dem Netz, das geht in der Nix-Sandbox nicht).
  #
  # Zig 0.17.1 und Flutter 3.47 kommen aus nixpkgs-unstable (26.05 hat nur ältere); der Workflow
  # nimmt Flutter 3.47.9 (siehe .github/actions/setup). Android-SDK und NDK in den Versionen, die
  # Flutter 3.47 und AGP 9.1 verlangen (unfrei, Lizenz hier akzeptiert).
  description = "mync – Devshell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    # nur für die Git-Hooks (lib/hooks.nix)
    project.url = "git+https://codeberg.org/MrKleeblatt/project-flake";
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,
      project,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      unstable = import nixpkgs-unstable {
        inherit system;
        config = {
          # für die Teile des Android-SDK (platform-tools, build-tools, NDK, …)
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };
      # compileSdk und ndkVersion aus Flutter (FlutterExtension.kt), Build-Tools aus AGP
      buildTools = "36.0.0";
      android =
        (unstable.androidenv.composeAndroidPackages {
          platformVersions = [ "36" ];
          buildToolsVersions = [ buildTools ];
          includeNDK = true;
          ndkVersions = [ "28.2.13676358" ];
          # das Plugin jni baut seinen nativen Teil mit dem CMake des SDK
          includeCmake = true;
          cmakeVersions = [ "3.22.1" ];
        }).androidsdk;
      androidHome = "${android}/libexec/android-sdk";
      # jeder Merge auf master ist ein Release
      branch = "master";
      hooks = pkgs.callPackage "${project}/lib/hooks.nix" { inherit branch; };
    in
    {
      # mit Compiler aus unstable wie Flutter: CMake baut die Linux-App
      devShells.${system}.default = unstable.mkShell {
        packages = [
          unstable.zig_0_17
          unstable.flutter347
          # Linux-App: GTK über pkg-config, libmpv für media_kit; aus demselben nixpkgs wie Flutter
          unstable.pkg-config
          unstable.gtk3
          unstable.mpv-unwrapped
          android
        ]
        ++ (with pkgs; [
          # wie in project-flake
          git
          just
          jq
          nixfmt
          yamllint
          # GitHub: Secrets, Releases, Schutzregeln
          gh
          # Android-Signaturschlüssel: keytool (Java 21 wie im Workflow), Signatur prüfen,
          # Passwort in die Zwischenablage
          jdk21
          apksigner
          xclip
          # tools/release
          python3
        ]);
        # media_kit lädt libmpv per dlopen
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ unstable.mpv-unwrapped ];
        ANDROID_HOME = androidHome;
        ANDROID_SDK_ROOT = androidHome;
        # das aapt2 von Maven läuft unter NixOS nicht, das aus dem SDK schon
        GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidHome}/build-tools/${buildTools}/aapt2";
        shellHook = ''
          # Hooks aus project-flake: kein Commit auf und kein Push nach ${branch}
          if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
            git -C "$root" config core.hooksPath ${hooks}
          fi
        '';
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
