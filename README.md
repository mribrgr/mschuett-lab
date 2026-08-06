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