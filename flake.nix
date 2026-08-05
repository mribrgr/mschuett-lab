{
  description = "mschuett-lab — Infra Stein aber Fein / M. Schütt (netcup ARM, k3s + ArgoCD)";

  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-26.05";
    };
    nixpkgs-unstable = {
      url = "github:nixos/nixpkgs/nixos-unstable";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    import-tree = {
      url = "github:vic/import-tree";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    # Geteilte Module (base/) aus dem zentralen nix-config.
    #
    # BEWUSST als gepinnter Input und NICHT als relativer Pfad `../base`:
    # mschuett-lab ist ein EIGENES Repo (anderer Gesellschafter) und muss
    # standalone evaluieren. Die anderen Welten (mac/, homelab/, lab/) liegen
    # IM nix-config-Repo und dürfen `../base` benutzen — diese Welt nicht.
    # Nebeneffekt (gewollt): base/ ist hier über flake.lock gepinnt, ein
    # base-Umbau in nix-config kann diese Kunden-/Gesellschafter-Infra nicht
    # unangekündigt umkonfigurieren. Update bewusst via:
    #   nix flake update nix-config
    #
    # flake = false: base/ ist kein Flake, sondern ein Modul-VERZEICHNIS.
    #
    # ⚠️ BRANCH, nicht main: die Vier-Welten-Struktur mit base/ liegt (Stand
    # 2026-08-05) auf refactor/multiworld-restructure. Auf main existiert base/
    # NICHT (dort nur homelab/). Nach dem Merge auf main hier umstellen auf
    #   url = "github:mribrgr/nix-config";
    # git+https statt github:: der github-Fetcher kann Branch-Namen MIT SLASH nicht
    # auflösen (er encodiert zu refactor%2F… und die commits-API antwortet 404).
    # https statt ssh, weil für dieses Konto KEIN SSH-Key bei GitHub liegt
    # (`gh auth`: "Git operations protocol: https"); die Credentials kommen aus
    # dem osxkeychain-Credential-Helper.
    #
    # Für den Deploy irrelevant, dass nix-config privat ist: `nixos-rebuild
    # --target-host` / nixos-anywhere baut die Closure LOKAL und schiebt sie auf
    # die Box — der Server fetcht keine Inputs und braucht keinen GitHub-Zugang.
    nix-config = {
      url = "git+https://github.com/mribrgr/nix-config?ref=refactor/multiworld-restructure";
      flake = false;
    };
  };

  outputs =
    { flake-parts, import-tree, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-linux"
      ];

      # Gleiche Reihenfolge/Struktur wie lab/flake.nix, nur base/ über den Input.
      # base/secrets/ bleibt außen vor: die agenix-Rules-Datei ist kein Modul.
      imports = [
        (import-tree [
          (inputs.nix-config + "/base/configurations")
          (inputs.nix-config + "/base/modules")
          ./modules
          ./hosts
          ./users
        ])
      ];
    };
}
