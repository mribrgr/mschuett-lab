# Hardware definition
## Installation
```
./setup-netcup.sh
```

## Update
```
darwin-rebuild switch --flake .#netcup --target-host "root@netcup-vps"
```

# 2025-05-31 New try
## Netcup server setup
Install k3sup via:
```shell
nix shell nixpkgs#k3sup
```

Create ssh key in order to access the server
```shell
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_netcup_max_1
```
Add the public key to netcup in the installation process of ubuntu 24.04.
```shell
cat ~/.ssh/id_netcup_max_1.pub
```
servercontrolpanel.de in the user settings "SSH Keys"
Server -> Media -> Images -> Ubuntu 24.04 -> Minimal -> small partition layout & ssh key -> reinstall
<!-- Passwort: Apple Passwords, Eintrag "netcup VPS root" — NICHT hier ablegen (Repo ist public) -->
Copy and save the password

Update ssh config:
```shell
echo "Host netcup_max_1
    HostName v2202505270128345138.powersrv.de
    User root
    IdentityFile ~/.ssh/id_netcup_max_1
" >> ~/.ssh/config
```

Try to connect
``` shell
ssh netcup_max_1
```

If successful, run script:
```shell
./2025-05-31_setup.sh
```

If successful, try to connect to single node cluster:
```shell
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get node -o wide
```

## ArgoCD install
(I used this tutorial: https://www.arthurkoziel.com/setting-up-argocd-with-helm/)

Install k3sup via:
```shell
nix shell nixpkgs#kubernetes-helm
```

Install argocd
```shell
helm repo add argo-cd https://argoproj.github.io/argo-helm
helm dep update charts/argo-cd/
helm install argo-cd charts/argo-cd/
```

Accessing web ui
```shell
kubectl port-forward svc/argo-cd-argocd-server 8080:443
```

Username: admin
Password from:
```shell
kubectl get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```
<!-- ArgoCD-admin-Passwort: Apple Passwords, Eintrag "ArgoCD netcup" -->

```shell
# TODO: argocd isn't able to connect to private repo, don't know why though

# install argocd cli
# nix shell nixpkgs#argocd
# argocd login --core
# add ssh key for gh
# ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_argo_gh_hardware
# add to github project deploy token
# argocd repo add git@github.com:mribrgr/hardware.git --ssh-private-key-path ~/.ssh/id_argo_gh_hardware

# initial root app
helm template charts/root-app/ | kubectl apply -f -
```

## chat.mauritiusberger.de — OpenWebUI + Kanidm-SSO (Namespace `chat`)

Deklarativ in `modules/{chat-namespace,kanidm,openwebui}.nix`, ausgeliefert als
`services.k3s.manifests` mit nix:0-Images. Design und Verifikationsstand:
`nix-config/docs/superpowers/specs/2026-08-26-openwebui-kanidm-netcup-design.md`.

```
Internet :443 → Cilium Envoy (Gateway default/main, LE-Certs vom cert-manager)
  ├─ chat.mauritiusberger.de → Svc open-webui:8080 → Pod open-webui (PVC /data)
  └─ idm.mauritiusberger.de  → Svc kanidm:8080     → Pod kanidm
                                                      ├ init  tls-init  (Self-Signed → emptyDir)
                                                      ├ ctr   nginx     :8080 → https://127.0.0.1:8443
                                                      ├ ctr   kanidmd   127.0.0.1:8443 (PVC /data)
                                                      └ ctr   provision recover-account + kanidm-provision
```

### Bauen: NICHT auf diesem Node
`open-webui` ist in nixpkgs **unfree** und `kanidm_1_11.withSecretProvisioning` ist ein
gepatchter Rust-Build — beides gibt es nicht im Binary-Cache. Am 2026-08-26 riss der
Vite-Frontend-Build (~3,9 GB RSS) diesen Node in load 53, der kube-apiserver antwortete
nicht mehr. Seitdem gilt: **aarch64-linux-Closures baut die Builder-VM des MacBooks**
(`nix-config/mac/modules/linux-builder.nix`), und nur die fertige Closure wird kopiert:

```bash
# in der VM bauen (Flake ohne .git rsyncen; der Submodul-Gitlink zeigt sonst ins Leere)
rsync -a --delete --exclude .git ./ builder-vm:deploy/mschuett-lab/
ssh builder-vm 'nix build --no-link --print-out-paths \
  "path:/home/builder/deploy/mschuett-lab#nixosConfigurations.netcup.config.system.build.toplevel" \
  --override-input nix-config path:/home/builder/deploy/nc-slim'
# Closure rüber und aktivieren
nix copy --no-check-sigs --from ssh-ng://builder-vm --to ssh-ng://root@netcup "$NEW"
ssh netcup "nix run nixpkgs#nvd -- diff /run/current-system $NEW"
ssh netcup "nix-env -p /nix/var/nix/profiles/system --set $NEW && $NEW/bin/switch-to-configuration switch"
```
`nc-slim` ist ein Verzeichnis, das NUR `base/` aus nix-config enthält — ein `path:`-Input auf
das ganze Repo kopiert 1,7 GB pro Eval.

### Ein bewusst interaktiver Vorgang
Kanidm kann Personen-Credentials nicht provisionieren. Einmal pro Nutzer, im Pod:

```bash
kubectl -n chat exec deploy/kanidm -c provision -- \
  kanidmd scripting recover-account -c /config/server.toml idm_admin   # Passwort notieren
kubectl -n chat exec -it deploy/kanidm -c provision -- /bin/bash
  export HOME=/tmp
  kanidm login -D idm_admin -H https://127.0.0.1:8443 --accept-invalid-certs
  kanidm person credential create-reset-token mberger  -H https://127.0.0.1:8443 --accept-invalid-certs
  kanidm person credential create-reset-token mschuett -H https://127.0.0.1:8443 --accept-invalid-certs
```
⚠️ `--accept-invalid-certs`, **nicht** `-C /tls/chain.pem`: das Loopback-Zertifikat ist sein
eigener Issuer, rustls lehnt es als CA mit `CaUsedAsEndEntity` ab.

### Was nach einem open-webui-Versions-Bump zu prüfen ist
Die Env-Var-Namen sind nicht stabil (in 0.11 z.B. `OAUTH_GROUPS_CLAIM` statt
`OAUTH_GROUP_CLAIM`, `ENABLE_API_KEYS` im Plural). Nach jedem Bump: Login als `mberger` →
Rolle `admin`; Login als `mschuett` → sieht **nur** DeepSeek V4 Flash Latest.
`ENV = "prod"` muss gesetzt bleiben, sonst sind `/docs` und `/openapi.json` öffentlich.
