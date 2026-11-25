{
  # Flake im Repository: liefert das fertig gebaute Programm aus dem neuesten
  # Release (Linux-Tarball mit eigener, geprüfter flake.nix und flake.lock).
  # Die Adresse enthält keine Version, die steht nur in app/pubspec.yaml.
  #
  #   nix run github:MrKleeblatt/mync
  #   nix profile install github:MrKleeblatt/mync
  #
  # In einer NixOS- oder Home-Manager-Konfiguration als Paket:
  #   inputs.mync.url = "github:MrKleeblatt/mync";
  #   home.packages = [ mync.packages.${pkgs.stdenv.hostPlatform.system}.default ];
  #   # oder nixpkgs.overlays = [ mync.overlays.default ]; und pkgs.mync
  # Eigenes nixpkgs statt des im Release festgelegten:
  #   inputs.mync.inputs.release.inputs.nixpkgs.follows = "nixpkgs";
  description = "mync – Musikplayer mit Handy-Sync";

  inputs.release.url = "https://github.com/MrKleeblatt/mync/releases/latest/download/mync-linux-x86_64.tar.gz";

  outputs = { self, release }:
    let
      system = "x86_64-linux";
    in {
      packages.${system} = release.packages.${system};
      apps.${system} = release.apps.${system};
      checks.${system} = release.checks.${system};

      overlays.default = final: prev: {
        mync = release.packages.${final.stdenv.hostPlatform.system}.default;
      };
    };
}
