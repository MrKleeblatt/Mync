{
  # Liegt jedem Linux-Release bei (im Tarball unter mync/flake.nix) und
  # verpackt das fertig gebaute Programm. Vorlage: packaging/nix/flake.nix,
  # @VERSION@ setzt der Release-Workflow ein.
  #
  #   nix run https://github.com/MrKleeblatt/mync/releases/latest/download/mync-linux-x86_64.tar.gz
  #   nix profile install https://github.com/MrKleeblatt/mync/releases/download/v@VERSION@/mync-linux-x86_64.tar.gz
  #
  # oder entpackt: cd mync && nix run .
  description = "mync – Musikplayer mit Handy-Sync (fertig gebautes Flutter-Programm)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      version = "@VERSION@";
    in {
      packages.${system} = {
        default = self.packages.${system}.mync;

        mync = pkgs.stdenv.mkDerivation {
          pname = "mync";
          inherit version;
          src = ./.;

          nativeBuildInputs = with pkgs; [
            autoPatchelfHook
            wrapGAppsHook3
            makeWrapper
          ];

          buildInputs = with pkgs; [
            gtk3 glib pango harfbuzz atk cairo gdk-pixbuf
            zlib libepoxy fontconfig stdenv.cc.cc.lib
          ];

          # werden per dlopen geladen -> in den RPATH eintragen (libmpv lädt
          # media_kit aus der Flutter-Engine heraus; dafür setzt der Wrapper
          # zusätzlich LD_LIBRARY_PATH, s. postFixup)
          runtimeDependencies = with pkgs; [
            libGL
            mpv-unwrapped
          ];

          # libdartjni.so (Java-Brücke einer Abhängigkeit) braucht libjvm nur
          # auf Android; unter Linux wird sie nie geladen
          autoPatchelfIgnoreMissingDeps = [ "libjvm.so" ];

          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            runHook preInstall
            mkdir -p $out/opt/mync $out/bin
            cp -r mync lib data VERSION $out/opt/mync/
            # Anwendungsmenü und Symbol
            install -Dm644 share/applications/mync.desktop $out/share/applications/mync.desktop
            install -Dm644 share/icons/hicolor/scalable/apps/mync.svg \
              $out/share/icons/hicolor/scalable/apps/mync.svg
            runHook postInstall
          '';

          # Das Programm bleibt neben lib/ und data/ in opt/mync (Flutter sucht
          # sie dort); bin/mync ist ein Wrapper mit den GTK-Umgebungsvariablen.
          # Selbst-Update aus: Nix bestimmt den Stand (nix profile upgrade).
          dontWrapGApps = true;
          postFixup = ''
            makeWrapper $out/opt/mync/mync $out/bin/mync \
              "''${gappsWrapperArgs[@]}" \
              --set MYNC_NO_SELF_UPDATE 1 \
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.mpv-unwrapped pkgs.libGL ]}
          '';

          meta = {
            description = "Musikplayer im Stil von Musicolet mit Handy-Sync";
            homepage = "https://github.com/MrKleeblatt/mync";
            mainProgram = "mync";
            platforms = [ system ];
            sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
          };
        };
      };

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/mync";
      };

      # „nix flake check“: Kern lädt, Programm ist vollständig gelinkt
      checks.${system}.default = pkgs.runCommand "mync-check" { } ''
        pkg=${self.packages.${system}.default}
        test -x $pkg/bin/mync
        test -f $pkg/opt/mync/lib/libmync_core.so
        ! ${pkgs.glibc.bin}/bin/ldd $pkg/opt/mync/mync | grep "not found"
        ! ${pkgs.glibc.bin}/bin/ldd $pkg/opt/mync/lib/*.so | grep "not found"
        touch $out
      '';
    };
}
