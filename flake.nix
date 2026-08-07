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
    # nix:0-Images (nix-snapshotter). Gleiche Quelle wie nix-config/lab.
    # KEIN nixpkgs.follows: das Flake baut gegen sein eigenes nixpkgs, ein
    # Override bricht den Build (gleiche Begründung wie bei hermes/collana im lab).
    nix-snapshotter = {
      url = "github:pdtpartners/nix-snapshotter";
    };

    # Quelle der Website steinaberfein.de. Als Input statt als Container-Image:
    # damit pinnt flake.lock die Website-Version, und `nix flake update
    # steinaberfeinde` ist der Update-Weg — kein Image-Digest, keine Registry.
    steinaberfeinde = {
      url = "github:mribrgr/steinaberfeinde";
      flake = false;
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # Geteilte Module (base/) aus dem zentralen nix-config.
    #
    # ── Warum hier ein GIT-Input steht und kein lokaler Pfad ──────────────────
    # Ziel war „immer gegen die lokale nix-config evaluieren, ohne jedes Mal
    # `nix flake update`". Mit `url = "path:/Users/.../nix-config"` geht das NICHT:
    # `path:`-Inputs werden ebenfalls über narHash gepinnt, jede Änderung an base/
    # bricht die Evaluation dann mit (2026-08-05 empirisch geprüft):
    #   error: NAR hash mismatch in input 'path:/Users/.../nix-config?narHash=sha256-c5Dx…'
    #   expected 'sha256-c5Dx…' but got 'sha256-Ygq…'
    # Das ist prinzipiell so: eine reine Flake-Evaluation kann kein veränderliches
    # externes Verzeichnis lesen — der Lock IST der Mechanismus. Ein `import` per
    # absolutem Pfad wäre impure und wird abgelehnt.
    #
    # Deshalb: committed steht der portable git-Input, und für die tägliche Arbeit
    # wird pro Aufruf überschrieben (kein Lock-Churn, kein flake update):
    #
    #   nix eval --override-input nix-config path:$HOME/projects/nix-config \
    #     .#nixosConfigurations.netcup.config.networking.hostName
    #
    #   nixos-rebuild switch --flake .#netcup \
    #     --override-input nix-config path:$HOME/projects/nix-config \
    #     --target-host root@… --build-on-remote
    #
    # Siehe TODO.md 0c. Sobald base/ gepusht ist, ist der Override unnötig.
    #
    # ⚠️ BRANCH, nicht main: die Vier-Welten-Struktur mit base/ liegt (Stand
    # 2026-08-05) auf refactor/multiworld-restructure; auf main existiert base/
    # nicht. git+https statt github:, weil der github-Fetcher Branch-Namen MIT
    # SLASH nicht auflöst (encodiert zu refactor%2F…, commits-API antwortet 404).
    #
    # flake = false: base/ ist kein Flake, sondern ein Modul-VERZEICHNIS.
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

      # Struktur wie lab/flake.nix — import-tree über die Verzeichnisse, keine
      # manuelle Dateiliste. base/ kommt über den Input statt über `../base`,
      # weil dieses Repo außerhalb von nix-config liegt.
      #
      # base/_network.nix wird dabei automatisch übersprungen (Unterstrich-Präfix
      # = reine Daten, kein Modul); modules/k3s.nix liest es direkt per `import`.
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
