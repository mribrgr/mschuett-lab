{ ... }:
{
  # Deklaratives ArgoCD-Bootstrap.
  #
  # Ersetzt die HANDARBEIT aus der alten README:
  #   helm install argo-cd charts/argo-cd/
  #   helm template charts/root-app/ | kubectl apply -f -
  # Beides lief bisher einmalig per Hand — nach einem Neuaufbau war der Cluster
  # ohne diese zwei Schritte leer. k3s applied Manifeste aus
  # /var/lib/rancher/k3s/server/manifests beim Start selbst, damit ist der
  # Bootstrap Teil der Systemgeneration statt eines Runbook-Schritts.
  #
  # ⚠️ DOPPELVERWALTUNG: sobald root-app läuft, verwaltet es
  # charts/root-app/templates/argo-cd.yaml — eine ArgoCD-Application, die ArgoCD
  # SELBST installiert. Gemeinsam mit dem HelmChart unten hätte die Release ZWEI
  # Verwalter (k3s-helm-controller + ArgoCD), die sich gegenseitig überschreiben.
  # Beim Neuaufbau daher charts/root-app/templates/argo-cd.yaml ENTFERNEN; dieses
  # Modul ist dann die einzige Quelle für ArgoCD selbst.
  flake.modules.nixos.argocd =
    { config, lib, ... }:
    {
      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        # Chart-Version 8.0.0 = exakt die Version, die der abgelöste Cluster fuhr
        # (charts/argo-cd/Chart.lock). Werte 1:1 aus charts/argo-cd/values.yaml.
        argo-cd.content = [
          {
            apiVersion = "helm.cattle.io/v1";
            kind = "HelmChart";
            metadata = {
              name = "argo-cd";
              namespace = "kube-system";
            };
            spec = {
              repo = "https://argoproj.github.io/argo-helm";
              chart = "argo-cd";
              version = "8.0.0";
              targetNamespace = "default";
              valuesContent = ''
                dex:
                  enabled: false
                notifications:
                  enabled: false
                applicationSet:
                  enabled: false
                server:
                  extraArgs:
                    - --insecure
              '';
            };
          }
        ];

        # App-of-Apps. Ab hier zieht ArgoCD alles Weitere aus charts/root-app/
        # (cert-manager, sealed-secrets, mongodb-operator, bricklink-scraping,
        # steinaberfeinde, notjustadevelopercom, rabbitmq-operator).
        #
        # sync-wave/Reihenfolge bleibt wie im Chart definiert. Kein prune hier:
        # root-app soll sich beim Bootstrap nicht selbst wegräumen.
        root-app.content = [
          {
            apiVersion = "argoproj.io/v1alpha1";
            kind = "Application";
            metadata = {
              name = "root-app";
              namespace = "default";
              finalizers = [ "resources-finalizer.argocd.argoproj.io" ];
            };
            spec = {
              project = "default";
              source = {
                repoURL = "https://github.com/mribrgr/mschuett-lab.git";
                path = "charts/root-app/";
                targetRevision = "HEAD";
              };
              destination = {
                server = "https://kubernetes.default.svc";
                namespace = "default";
              };
              syncPolicy.automated.selfHeal = true;
            };
          }
        ];
      };
    };
}
