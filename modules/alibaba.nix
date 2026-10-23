{
  inputs,
  lib,
  self,
  ...
}:
{
  # Ali-Baba-Landingpages als nix:0-Images (nix-snapshotter), statisch, darkhttpd.
  #
  # Zwei Hosts, je eine Seite (beide "Bundled Page"-Exports, also fully
  # self-contained — alle Bilder als Base64 im JS-Bund, keine externen/relativen
  # Asset-Referenzen, verifiziert 2026-10-23):
  #   alibaba-rot.mauritiusberger.de  → web/alibaba-rot/index.html   (warmes Rot/Braun)
  #   alibaba-blau.mauritiusberger.de → web/alibaba-blau/index.html  (Mitternachtsblau)
  #
  # Gleiche Begründung wie bei steinaberfein.de (siehe modules/steinaberfeinde.nix):
  # ein nix:0-Ref IST ein Store-Pfad und ändert sich mit jedem Inhalt, den ein
  # Helm-Chart in git nicht kennen kann. Deshalb hier als `services.k3s.manifests`
  # statt als ArgoCD-Application. Content liegt IN diesem Repo unter web/, die
  # Version ist also der Git-Commit — kein zweites Repo, kein flake-Input.
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    let
      # ⚠️ buildImage über eine EIGENE pkgs-Instanz mit dem nix-snapshotter-Overlay,
      # nicht über `inputs.nix-snapshotter.packages.<system>`: das Flake liefert die
      # Pakete nur für x86_64-linux, auf aarch64-netcup gibt es dort nichts. Der
      # Overlay baut nix-snapshotter aus dem Source (Go, portabel) → läuft auf aarch64
      # (gleicher Hinweis wie steinaberfeinde.nix).
      #
      # darkhttpd statt nginx: rein statisch, ein Binary, keine Config-Datei, kein
      # Worker-User-Drop, keine temp-Verzeichnisse → kleine Closure, wenig was bricht.
      makeSite =
        name:
        let
          pkgsSnap = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          # cleanSource, nicht getSrc: getSrc wirft ohne .git-Checkout — und der
          # dokumentierte Netcup-Bauweg rsynct das Flake EXKLUSIV `--exclude .git`
          # (README "Kleine Änderungen"). cleanSource filtert nur, braucht kein Git.
          site = lib.cleanSource (self + "/web/${name}");
        in
        pkgsSnap.nix-snapshotter.buildImage {
          inherit name;
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
    in
    {
      packages.alibaba-rot-image = makeSite "alibaba-rot";
      packages.alibaba-blau-image = makeSite "alibaba-blau";
    };

  # ── Auslieferung per k3s-Manifest (NICHT ArgoCD) ─────────────────────────────
  # Begründung oben: der nix:0-Ref ist ein Store-Pfad, den nur nix kennt. Durch die
  # String-Interpolation des Image-Derivats landet der Image-Tar automatisch in der
  # System-Closure des Nodes — kein extraDependencies nötig.
  #
  # Der TLS-Listener pro Host steht NICHT hier, sondern in
  # charts/root-app/templates/gateway.yaml (ArgoCD-Quelle) — wie bei allen übrigen
  # *.mauritiusberger.de-Hosts. Beide Seiten (Listener + Route) liegen im selben
  # Repo, gehen aber über zwei Quellen live (Flake → k3s, Chart → ArgoCD). Für einen
  # NEUEN Host ohne Bestand gibt es kein Reihenfolge-Problem: die HTTPRoute hängt
  # kurz ins Leere, bis der Listener da ist — die Seite ist dann erst erreichbar,
  # wenn beides steht.
  flake.modules.nixos.alibaba =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      rotImg = self.packages.${pkgs.stdenv.hostPlatform.system}.alibaba-rot-image;
      blauImg = self.packages.${pkgs.stdenv.hostPlatform.system}.alibaba-blau-image;

      # [Deployment; Service; HTTPRoute] für einen Host. group/kind/weight explizit
      # (wie in der NJD-HTTPRoute), damit der Diff gegen das Live-Objekt sauber
      # bleibt und ServerSideApply keine Defaults als Drift meldet.
      site =
        name:
        {
          image,
          host,
        }:
        [
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              inherit name;
              namespace = "default";
            };
            spec = {
              replicas = 1;
              selector.matchLabels.app = name;
              template = {
                metadata.labels.app = name;
                spec.containers = [
                  {
                    inherit name;
                    # nix:0 — vom nix-snapshotter aufgelöst, kein Registry-Pull.
                    # IfNotPresent, NICHT Never (ErrImageNeverPull, vgl. steinaberfeinde.nix).
                    image = image.image;
                    imagePullPolicy = "IfNotPresent";
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
              inherit name;
              namespace = "default";
            };
            spec = {
              selector.app = name;
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
              inherit name;
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
              hostnames = [ host ];
              rules = [
                {
                  matches = [ { path = { type = "PathPrefix"; value = "/"; }; } ];
                  backendRefs = [
                    {
                      group = "";
                      kind = "Service";
                      name = name;
                      port = 80;
                      weight = 1;
                    }
                  ];
                }
              ];
            };
          }
        ];
    in
    {
      # `services.k3s.manifests` ist `lazyAttrsOf (submoduleOf …)`: jeder Key ein
      # Modul mit `.content = [ Doku; … ]` — genau wie steinaberfeinde/gatus.
      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        alibaba-rot.content = site "alibaba-rot" {
          image = rotImg;
          host = "alibaba-rot.mauritiusberger.de";
        };
        alibaba-blau.content = site "alibaba-blau" {
          image = blauImg;
          host = "alibaba-blau.mauritiusberger.de";
        };
      };
    };
}
