{
  inputs,
  self,
  lib,
  ...
}:
{
  # steinaberfein.de als nix:0-Image (nix-snapshotter) statt als OCI-Image aus ghcr.
  #
  # ── Warum das NICHT über ArgoCD läuft ────────────────────────────────────────
  # Ein nix:0-Ref IST ein Store-Pfad (`nix:0/nix/store/<hash>-image.json`) und
  # ändert sich mit jedem Inhalt. Ein Helm-Chart in git kann diesen Hash nicht
  # kennen — nur nix kennt ihn zur Eval-Zeit. Deshalb wird dieser Workload als
  # `services.k3s.manifests` ausgeliefert und nicht als ArgoCD-Application.
  #
  # Das ist eine bewusste AUSNAHME von der Regel „GitOps für App-Level, nix für
  # Cluster-Level" (TODO.md 0b). Sie ist auf genau die Workloads begrenzt, die als
  # nix:0 laufen — hier vertretbar, weil die Seite statisch ist und keinerlei
  # Runtime-Konfiguration hat, die man über ArgoCD drehen wollte.
  #
  # ── Was dadurch wegfällt ─────────────────────────────────────────────────────
  # Kein Dockerfile, kein CI-Build, kein ghcr-Push, kein Image-Digest im Chart.
  # Die Website-Version pinnt `flake.lock` über den `steinaberfeinde`-Input.
  # Update der Seite:  nix flake update steinaberfeinde && nixos-rebuild switch
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    {
      packages.steinaberfeinde-image =
        let
          # ⚠️ Anders als im lab NICHT über `inputs.nix-snapshotter.packages.<system>`:
          # das Flake veröffentlicht Pakete AUSSCHLIESSLICH für x86_64-linux
          # (verifiziert 2026-08-07: `builtins.attrNames f.packages` → ["x86_64-linux"]).
          # Auf dem aarch64-netcup gibt es dort schlicht nichts. Das lab ist x86_64,
          # deshalb fällt das dort nicht auf.
          #
          # Der Overlay baut nix-snapshotter dagegen aus dem Source (Go, portabel) und
          # liefert `buildImage` auch auf aarch64 — verifiziert.
          #
          # Der Overlay wird bewusst auf eine EIGENE pkgs-Instanz angewandt und nicht
          # auf die des Flakes: genau davor warnt der Kommentar in
          # nix-config/lab/modules/tests/azure-k3s-integration.nix (Diamond-Problem auf
          # services.k3s.package). Lokal begrenzt gibt es das Problem nicht.
          pkgsSnap = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          nixSnapshotter = pkgsSnap.nix-snapshotter;

          # darkhttpd statt nginx: die Seite ist rein statisch. darkhttpd ist ein
          # einzelnes Binary, braucht keine Config-Datei, keine /etc/passwd (nginx
          # will seine Worker auf einen User droppen, den ein minimales Image nicht
          # hat) und keine beschreibbaren temp-Verzeichnisse. Deutlich kleinere
          # Closure und weniger, was schiefgehen kann.
          site = inputs.steinaberfeinde;
        in
        nixSnapshotter.buildImage {
          name = "steinaberfeinde";
          resolvedByNix = true;
          config = {
            entrypoint = [
              "${pkgs.darkhttpd}/bin/darkhttpd"
              "${site}"
              "--port"
              "80"
              # Kein Directory-Listing für Verzeichnisse ohne index.html.
              "--no-listing"
            ];
          };
        };
    };

  # ── Auslieferung per k3s-Manifest (NICHT ArgoCD) ─────────────────────────────
  # Begründung oben im Kopf: der nix:0-Ref ist ein Store-Pfad, den nur nix kennt.
  # Durch die String-Interpolation des Image-Derivats landet der Image-Tar
  # automatisch in der System-Closure des Nodes — kein extraDependencies nötig.
  flake.modules.nixos.steinaberfeinde =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      img = self.packages.${pkgs.stdenv.hostPlatform.system}.steinaberfeinde-image;
    in
    {
      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        steinaberfeinde.content = [
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "steinaberfeinde";
              namespace = "default";
            };
            spec = {
              replicas = 1;
              selector.matchLabels.app = "steinaberfeinde";
              template = {
                metadata.labels.app = "steinaberfeinde";
                spec.containers = [
                  {
                    name = "steinaberfeinde";
                    # nix:0 — wird vom nix-snapshotter aufgelöst, kein Registry-Pull.
                    image = img.image;
                    # Never: das Image kommt aus dem Store, nicht aus einer Registry.
                    # Bei Always würde der kubelet vergeblich zu ziehen versuchen.
                    imagePullPolicy = "Never";
                    ports = [ { containerPort = 80; } ];
                  }
                ];
              };
            };
          }
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "steinaberfeinde";
              namespace = "default";
            };
            spec = {
              selector.app = "steinaberfeinde";
              ports = [
                {
                  protocol = "TCP";
                  port = 80;
                  targetPort = 80;
                }
              ];
            };
          }
          {
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "HTTPRoute";
            metadata = {
              name = "steinaberfeinde";
              namespace = "default";
            };
            spec = {
              parentRefs = [
                {
                  group = "gateway.networking.k8s.io";
                  kind = "Gateway";
                  name = "main";
                  namespace = "default";
                }
              ];
              hostnames = [
                "steinaberfein.de"
                "www.steinaberfein.de"
              ];
              rules = [
                {
                  matches = [ { path = { type = "PathPrefix"; value = "/"; }; } ];
                  backendRefs = [
                    {
                      group = "";
                      kind = "Service";
                      name = "steinaberfeinde";
                      port = 80;
                      weight = 1;
                    }
                  ];
                }
              ];
            };
          }
        ];
      };
    };
}
