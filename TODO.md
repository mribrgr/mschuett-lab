# mschuett-lab — offene Punkte

Stand: 2026-08-05

## 0. Cutover-Runbook (Entscheidung: primäre VM, Downtime akzeptiert)

Kein Probe-Host. Der Umbau läuft direkt auf `v2202505270128345138.powersrv.de`.
Absicherung ist das Backup `mschuett-lab-premigration-20260805` (velero/kopia,
Azure Blob `azureresticbackup`/Container `netcup`, Completed, 0 Fehler, 36 Volumes,
läuft bis 2026-11-03).

IP und DNS bleiben gleich (dieselbe VM, nur Neuinstallation) — keine DNS-Änderung
nötig.

1. **Frisches Backup ziehen** und `phase=Completed` prüfen:
   ```sh
   velero backup create pre-cutover-$(date +%Y%m%d) -n default \
     --snapshot-volumes=false --default-volumes-to-fs-backup --ttl 2160h --wait
   ```
   `--snapshot-volumes=false` ist wichtig: sonst kippt das Backup wegen des
   vestigialen Azure-VolumeSnapshotLocation auf `PartiallyFailed` (fehlendes
   `AZURE_SUBSCRIPTION_ID`; betrifft keine Daten, siehe Analyse 2026-08-05).

2. **Install** — wischt die Platte, baut auf dem Ziel:
   ```sh
   nixos-anywhere --flake .#netcup \
     --target-host root@v2202505270128345138.powersrv.de \
     --generate-hardware-config nixos-facter ./facter.json \
     --build-on-remote
   ```

3. **Sealed-Secrets-Keys einspielen**, sobald k3s erreichbar ist:
   ```sh
   agenix -d secrets/sealed-secrets-master-keys.age | kubectl apply -f -
   kubectl -n kube-system rollout restart deploy/sealed-secrets
   ```
   Reihenfolge ist **nicht kritisch, nur unangenehm**: hat der frische Controller
   schon einen eigenen Key erzeugt, ist nichts verloren — er lädt ALLE Secrets mit
   Label `sealedsecrets.bitnami.com/sealed-secrets-key` und nutzt sie zum
   Entschlüsseln (der neue bleibt nur der aktive Sealing-Key). Nachträgliches
   Einspielen + Restart heilt den Zustand.

4. **ArgoCD durchsyncen lassen.** Reihenfolge ergibt sich: cert-manager →
   sealed-secrets → notjustadevelopercom (bringt velero mit) → steinaberfeinde.
   `velero-credentials` entschlüsselt erst, wenn Schritt 3 erledigt ist.

5. **Daten zurückholen.** Achtung: ArgoCD legt die PVCs leer neu an, velero will
   in dieselben restaurieren. Entweder vor dem App-Sync restaurieren oder:
   ```sh
   velero restore create --from-backup mschuett-lab-premigration-20260805 \
     -n default --existing-resource-policy=update
   ```

6. **Verifizieren:** `steinaberfein.de` + `*.mauritiusberger.de` erreichbar, TLS
   gültig, paperless/n8n/grocy haben ihre Daten, postgres 91 MB.
   Let's-Encrypt-**prod** hat ein Limit von 5 identischen Zertifikaten pro Woche —
   bei Wiederholungen auf `letsencrypt-staging` wechseln, sonst ist die Woche
   verbrannt.

Nicht Teil des Cutovers: bricklink-scraping (Punkt 1) — startet später mit leerer
MongoDB.

## 0b. charts/ → Module: was wandert, was bleibt

Regel (2026-08-05 beschlossen): **GitOps für App-Level, nix für Cluster-Level.**

**Bleibt in `charts/root-app/templates/` (ArgoCD):** `steinaberfeinde`,
`notjustadevelopercom`, später `bricklink-scraping`. Echte Anwendungen — profitieren
von Image-Tag-Bumps, Sync-History und ArgoCD-UI.

**Wandert nach `modules/` als `services.k3s.manifests`:**

- ✅ `argo-cd` + `root-app` → `modules/argocd.nix` (erledigt)
- ✅ `cilium` + Gateway-API-CRDs → `modules/k3s.nix` + `modules/gateway.nix` (erledigt)
- ✅ **`sealed-secrets` → Bootstrap** (`modules/sealed-secrets.nix`, Chart 2.17.7).
      Nicht Kosmetik, sondern Reihenfolge-Sicherheit: als ArgoCD-App war die Kette
      ArgoCD → sync sealed-secrets → Keys, und bis dahin scheiterte jeder Sync mit
      SealedSecret. Jetzt kommt der Controller mit dem Cluster hoch.
- ✅ **`cert-manager` → Bootstrap** (`modules/cert-manager.nix`, jetstack 1.18.2 +
      installCRDs) — die netcup-Variante, NICHT `lab/modules/cert-manager.nix`
      (dessen HTTP-01-Solver hängt am Cilium-Gateway; hier läuft TLS noch über
      traefik-Ingress).
      Die **ClusterIssuer bleiben in `charts/`**: sie sind Konfiguration
      (Kontakt-Mail, ACME-Server, Solver), keine Cluster-Infra — und der Wechsel
      staging↔prod soll ohne nixos-rebuild gehen, genau der Fall beim
      Let's-Encrypt-Prod-Limit. Weil cert-manager jetzt VOR ArgoCD existiert, sind
      die CRDs da, wenn ArgoCD die Issuer anlegt; die sync-waves "0"/"1" sind nur
      noch Dokumentation.
- [ ] `mongodb-community-operator` / `rabbitmq-cluster-operator` bleiben bei
      bricklink (dienen nur ihm), also weiter in `disabled/`.

Ergebnis (verifiziert 2026-08-05):

```
Bootstrap (nix)  argo-cd  cert-manager  cilium  gateway-api-crds  root-app  sealed-secrets
ArgoCD (Apps)    notjustadevelopercom  root-app  steinaberfeinde  + 2 ClusterIssuer
```

## 0f. SSH-Zugang: bewusst NICHT abstrahiert

Zwischenstand 2026-08-05, damit es nicht nochmal aufgerollt wird.

Verworfen wurden zwei Varianten:

1. **Identitäten in `base/_network.nix`** (`admin.publicKey`, `admin.identityFile`).
   Falsch: diese Datei ist der ADRESSPLAN („einzige Quelle der Wahrheit für Adressen
   und CIDRs"). Ein SSH-Key ist keine Adresse.
2. **Eigene `base/_identities.nix`** mit `identities` + `hostAccess`, aus der Host-
   und Client-Seite ableiten. Klingt sauber, brachte aber **keine** Deduplizierung:
   `ssh-client.nix` braucht einen PRIVATE-Key-PFAD, `users/root.nix` einen
   PUBLIC KEY — zwei verschiedene Werte. Es blieb Indirektion ohne Gewinn, plus eine
   Datei, die praktisch nur einen Konsumenten hatte.

**Gewählt:** so wenig Abstraktion wie möglich.

- Adressen: `base/_network.nix` (dort gehören sie hin).
- Public Keys: in der Host-Config, die den Zugang deklariert —
  `mschuett-lab/users/root.nix`, `lab/users/root.nix`.
- Private-Key-Pfad + User: literal in `mac/modules/ssh-client.nix`.
- **Konvention beibehalten:** neue Keys heißen `~/.ssh/id_<name>`. Bestandskeys
  weichen ab (historisch) und werden beim nächsten Anfassen mitgezogen — außer
  `id_ed25519`: das ist zugleich die agenix-Identity (`age.identityPaths`), ein
  Rename bricht jede Entschlüsselung.

Warum nicht aus den Host-Configs ableiten: der Mac müsste die
nixosConfigurations der anderen Welten evaluieren. Genau das schließt
`nix-config/flake.nix` aus („würde alle vier Locks in einen Eval ziehen").

- [ ] Nach dem Cutover: RSA-Key aus `mschuett-lab/users/root.nix` UND den Alias
      `netcup_max_1` aus `ssh-client.nix` entfernen. Dann bleibt genau ein Key.

## 0c. Arbeitsablauf bei base/-Änderungen (Zwei-Repo-Kopplung)

`base/` kommt als Flake-Input. **Immer mit Override gegen die lokale nix-config
arbeiten** — dann braucht es weder Push noch `nix flake update`:

```sh
nix eval --override-input nix-config path:$HOME/projects/nix-config \
  .#nixosConfigurations.netcup.config.services.k3s.extraFlags

nixos-rebuild switch --flake .#netcup \
  --override-input nix-config path:$HOME/projects/nix-config \
  --target-host root@v2202505270128345138.powersrv.de --build-on-remote
```

Ohne Override zieht der Input die **gepushte** Revision; ungepushte
base/-Änderungen schlagen dann so fehl (2026-08-05 gesehen):

```
error: expected a set but found a string: "10.32.0.0/16"
```

**Warum nicht einfach `url = "path:/Users/.../nix-config"`?** Getestet, geht nicht:
`path:`-Inputs werden **ebenfalls über narHash gepinnt**, jede base/-Änderung
bricht dann die Evaluation mit

```
error: NAR hash mismatch in input 'path:/Users/.../nix-config?narHash=sha256-c5Dx…'
expected 'sha256-c5Dx…' but got 'sha256-Ygq…'
```

Das ist prinzipiell so: eine **reine** Flake-Evaluation kann kein veränderliches
externes Verzeichnis lesen — der Lock IST der Mechanismus, und ein `import` per
absolutem Pfad wäre impure (wird abgelehnt). Es bleiben also genau zwei Wege:
`nix flake update nix-config` nach jeder Änderung, oder `--override-input` pro
Aufruf. Zweiteres gewählt: kein Lock-Churn, und die committete `flake.nix` bleibt
portabel (git-Input, maschinenunabhängig).

## 0d. Geplant, aber noch nicht drin

- [ ] **Gateway API statt Ingress.** Entscheidung 2026-08-06: NICHT beim Cutover,
      sondern als eigener Schritt. Grund: es hängt an zwei Repos gleichzeitig
      (`charts/steinaberfeinde/templates/ingress.yaml` HIER und `ingress.yaml` in
      not-just-a-developer.com für die fünf `*.mauritiusberger.de`-Hosts), plus
      Umbau der ClusterIssuer von `http01.ingress.class: traefik` auf einen
      `gatewayHTTPRoute`-Solver, plus LB-IPAM statt servicelb. Das an den
      Daten-Restore zu koppeln war das Risiko nicht wert.
      Aktuell daher: `gatewayAPI.enabled=false` in `modules/k3s.nix`,
      `modules/gateway.nix` NICHT importiert, traefik + servicelb aktiv.

      ⚠️ **BLOCKER für die Migration, gemessen 2026-08-06:** k3s' traefik-crd-Chart
      (40.1.3) installiert die Gateway-API-CRDs in **v1.5.1** —
      ```
      kubectl get crd gatewayclasses.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'
      → v1.5.1   (managed-by=Helm, release traefik-crd)
      ```
      Genau die Version, die laut nix-config/lab/modules/gateway.nix den
      Cilium-Operator bricht (cilium#45139; Cilium 1.18 will exakt v1.3.0).
      Reihenfolge bei der Migration deshalb zwingend:
        1. `--disable=traefik` + `--disable=servicelb` setzen, rebuilden
        2. traefiks v1.5.1-CRDs entfernen (die 5 gateway.networking.k8s.io-CRDs)
        3. `modules/gateway.nix` importieren (pinnt v1.3.0 per fetchurl)
        4. `gatewayAPI.enabled=true` + LB-IPAM-Pool aktivieren
        5. Ingress → HTTPRoute in beiden Repos, ClusterIssuer auf gateway-Solver
      Wer 3. vor 2. macht, bekommt wieder den Ownership-Konflikt von unten.
- [ ] **Longhorn** statt local-path. Heute hängt JEDE PVC an local-path RWO — auf
      einem Multi-Node-Cluster pinnt das jeden Pod auf netcup. Vor dem Agent-Beitritt
      klären, ob die 7,5 GB Mongo direkt nach Longhorn restauriert werden.
- [ ] **netbird**: `mesh.cidr` in `base/_network.nix` ist noch `PLATZHALTER`
      (`verified = false`). Erst nachziehen, wenn das Mesh real existiert — es ist
      Voraussetzung dafür, dass die Azure-Agents die netcup-CP erreichen.
- [ ] **Backup-Ziel NAS.** Bleibt vorerst velero → Azure Blob (funktioniert,
      verifiziert). Ziel ist das NAS, das dafür noch nicht eingerichtet ist. Wenn
      velero im neuen Setup nicht sauber läuft, ist das vorerst akzeptiert.
- ✅/[ ] **nix:0 — Realitätscheck (2026-08-07).** `steinaberfein.de` läuft als
      erstes nix:0-Image (`modules/steinaberfeinde.nix`), verifiziert:
      `image=nix:0/nix/store/…-nix-image-steinaberfeinde.tar`, Seite liefert 200
      mit gültigem TLS und korrekten MIME-Typen.

      „nix:0 überall" ist aber NICHT erreichbar, und das war vorher zu optimistisch
      formuliert. nix:0 setzt `nix-snapshotter.buildImage` voraus — das geht nur bei
      **selbst gebauten** Images. cilium, cert-manager, sealed-secrets, velero,
      postgres, redis, paperless, n8n, grocy, signal-api, coredns sind Fremd-Images
      und bleiben dauerhaft OCI. Realistische Kandidaten: genau drei —
      steinaberfein.de (erledigt), notjustadevelopercom, bl-sync.

      Drei Erkenntnisse, die Zeit gekostet haben:
      1. **nix-snapshotter veröffentlicht Pakete nur für x86_64-linux.**
         `builtins.attrNames f.packages` → `["x86_64-linux"]`. Auf aarch64 ist
         `inputs.nix-snapshotter.packages.<system>` schlicht leer. Das lab merkt das
         nicht, weil es x86_64 ist. Lösung: der **Overlay** baut aus dem Source und
         liefert `buildImage` auch auf aarch64 — angewandt auf eine LOKALE
         pkgs-Instanz, damit das Diamond-Problem aus dem lab nicht auftritt.
      2. **`imagePullPolicy: Never` ist falsch.** Der nix-snapshotter klinkt sich in
         den PULL ein; mit `Never` lehnt der kubelet vorher ab → `ErrImageNeverPull`.
         Richtig ist `IfNotPresent`.
      3. **nix:0 schließt ArgoCD aus.** Der Ref ist ein Store-Pfad, den nur nix zur
         Eval-Zeit kennt — ein Chart in git kann ihn nicht ausdrücken. Solche
         Workloads laufen deshalb über `services.k3s.manifests`. Bewusste Ausnahme
         von der Regel „GitOps für App-Level" (0b), begrenzt auf nix:0-Workloads.

      - [ ] notjustadevelopercom und bl-sync ebenfalls auf nix:0 — beide brauchen
            dafür denselben Repo-als-Input-Trick wie steinaberfeinde.
      - [ ] Falls gVisor kommt: nix:0 läuft NICHT unter runsc (0e).

## 0e. gVisor kommt später — was JETZT zu beachten ist

Kurz: **keine Konfiguration nötig**, aber drei Dinge dürfen nicht überraschen.
Eines davon ist ein clusterweiter Footgun.

1. ⚠️ **`socketLB.hostNamespaceOnly = true` in den Cilium-Values ist Pflicht, sobald
   gVisor dazukommt.** Hier ist `kubeProxyReplacement: true` gesetzt (Voraussetzung
   für die Gateway API). KPR aktiviert socketLB über den bpf-cgroup-connect-Hook,
   und der greift bei gVisor-Pods (runsc, Userspace-Netstack) NICHT → `pod→ClusterIP`
   bricht **clusterweit**, nicht nur für die Sandbox-Pods (im lab am 2026-07-22
   verifiziert). Fix ist der von Cilium dokumentierte Weg: socketLB nur im
   Host-Netns, Pod-Traffic über den tc/veth-bpf-LB. Reine Values-Änderung +
   `rollout restart ds/cilium` — also **kein Neuaufbau**, kann warten. Aber wer
   gVisor ohne diesen Flag einschaltet, legt den ganzen Cluster lahm.
2. **nix:0-Images laufen NICHT unter runsc.** Regel daraus: jeder Workload, der
   später sandboxed werden soll, darf NICHT als nix:0 gebaut werden (im lab traf es
   `signal-bridge` → zurück auf dockerTools). Heute ist hier nichts sandboxed,
   nix:0 also überall ok — aber eine spätere Sandbox-Entscheidung erzwingt einen
   Image-Rebuild.
3. **Registrierung** ist unspektakulär: `containerdConfigTemplate` mit dem
   `runsc`-Runtime-Handler (dabei `{{ template "base" . }}` ZWINGEND erhalten —
   CNI/Cgroup/snapshotter-Basis), `pkgs.gvisor` in `systemd.services.k3s.path`, plus
   eine RuntimeClass. k3s-Neustart, kein Neuaufbau. Vorlage: `lab/modules/k3s.nix`.
4. **arm64 prüfen.** runsc unterstützt aarch64, aber das lab fährt x86_64 — vor dem
   Einsatz hier einmal real verifizieren statt annehmen.
- [ ] **Legacy-SSH-Alias entfernen.** `netcup_max_1` in
      `nix-config/mac/modules/ssh-client.nix` existiert nur, weil die Ubuntu-Box
      ausschließlich den RSA-Key akzeptiert. Nach dem Cutover greift `netcup` mit
      `id_ed25519` (= der Key aus `users/root.nix`) — dann Alias und RSA-Key raus,
      auch aus `users/root.nix`.

## 0g. Cutover 2026-08-06 — vier Stolperfallen, alle bestätigt

Chronologisch, damit nichts davon zweimal Zeit kostet.

1. **Install brach nach dem Wipe ab.** nixos-anywhere liest mschuett-lab aus dem
   DIRTY Worktree, holt `nix-config` aber aus **git**. Ungepushte base/-Änderungen
   → `error: expected a set but found a string: "10.32.0.0/16"`, und zwar ERST beim
   Bauen der Closure, also nachdem disko die Platte schon gelöscht hatte.
   → base/ VOR dem Install pushen (Runbook Phase 0 Schritt 1), oder Fallback im
   Modul (siehe `nc = if builtins.isAttrs …` in modules/k3s.nix).

2. **NixOS-Firewall vs. Cilium — es ist NUR der Reverse-Path-Filter.**
   `checkReversePath` (Default "loose") baut `nixos-fw-rpfilter` in der
   **MANGLE**-Tabelle mit `-m rpfilter --validmark`. `--validmark` wertet die fwmark
   aus, Cilium routet über `ip rule … fwmark 0x200 lookup 2004` → Lookup landet in
   Ciliums Tabelle, validiert nicht, DROP. 137K Pakete, ~2/s.
   Zwei Gründe, warum es so schwer zu finden war: mangle PREROUTING läuft VOR INPUT
   (`trustedInterfaces` greift nie, `lxc+` stand auf 0 Paketen) und
   `logReversePathDrops` ist per Default false (kein Logeintrag).
   → `checkReversePath = false`, Firewall bleibt AN, Anti-Spoofing per Kernel-sysctl
   auf enp7s0. Symptom war coredns/metrics/local-path/alle helm-installs im
   CrashLoop — sah wie ein CNI-Totalschaden aus.

3. **sealed-secrets-Chart-Repo ist umgezogen.** `bitnami-labs` → `bitnami` am
   2026-06-15, GitHub Pages leitet NICHT weiter → 404. Der alte Cluster merkte es
   nie (installiert vor dem Umzug). → `https://bitnami.github.io/sealed-secrets`.

4. **`services.k3s.manifests` räumt NICHT auf.** Ein aus der Nix-Config ENTFERNTER
   Eintrag lässt die Datei in `/var/lib/rancher/k3s/server/manifests/` liegen, k3s
   applied sie weiter. Nach dem Entfernen von `gateway-api-crds` blieb
   `gateway-api-crds.yaml -> /nix/store/…-standard-install.yaml` bestehen und die
   CRDs kollidierten weiter mit traefik-crd. Das Löschen des k3s-`addon`-Objekts
   räumt cluster-scoped CRDs auch NICHT mit ab.
   → beim Entfernen eines Manifests: Datei UND ggf. die erzeugten Ressourcen von
   Hand wegräumen.

**Ergebnis:** netcup läuft auf NixOS 26.05, k3s 1.36.2, Cilium 1.18.12, embedded
etcd, Pod/Service-CIDR 10.60/10.70, Firewall aktiv. `steinaberfein.de` liefert 200
mit gültigem Let's-Encrypt-**Prod**-Zertifikat (issuer CN=YR1, 2026-08-06 →
2026-11-04). Offen: `notjustadevelopercom` (siehe 0h).

## 0i. ⛔ not-just-a-developer.com: NICHT anfassen

Entscheidung 2026-08-06. Das Repo `~/projects/not-just-a-developer.com` wird
**nicht bearbeitet und nie committet**. Der Cluster soll exakt das fahren, was vor
dem Wipe lief — also den gepushten Stand, nicht die lokalen Monate-alten Änderungen.

- Der lokale Klon ist **nicht** der Deploy-Stand: lokal `e9886dd`, Remote und von
  ArgoCD gesynct `4c4fef7`. Wer lokal liest, liest die falsche Revision.
- Der lokale Worktree hat unabhängige Drift (README, config.toml, .gitignore,
  gelöschtes content/first, mehrere neue content/-Ordner, untracked
  `deploy/chart/charts/` und mehrere `*-secret.yaml`). Alles bewusst ungepusht.
- Das Chart zieht `velero` als Abhängigkeit (12.0.1, vmware-tanzu). In `4c4fef7`
  sind nur `Chart.yaml` + `Chart.lock` eingecheckt, **nicht** `charts/` — ArgoCDs
  repo-server holt das Subchart also zur Render-Zeit übers Netz. Funktioniert
  (Pod-Egress ist seit dem rpfilter-Fix in Ordnung), ist aber die Erklärung, falls
  ein Sync mal an fehlendem Egress scheitert.

**Bewusst NICHT gefixt — Folge:** `4c4fef7` enthält weiterhin
`configuration.volumeSnapshotLocation: [{name: default, provider: azure}]`.
Die nächtlichen Backups bleiben damit `PartiallyFailed` (Ursache: velero
initialisiert das Azure-Snapshot-Plugin und scheitert an `AZURE_SUBSCRIPTION_ID`).
**Die Daten sind davon nicht betroffen** — 36/36 PodVolumeBackups Completed,
verifiziert 2026-08-05. Wer manuell sichert, nimmt weiterhin
`--snapshot-volumes=false`, dann steht am Ende `Completed`.

Wenn das irgendwann doch behoben werden soll, ist der Weg (getestet, dann
zurückgerollt): `velero.snapshotsEnabled: false` — NICHT nur die Einträge unter
`configuration.volumeSnapshotLocation` löschen, denn das Subchart hat dort einen
Default, der sonst greift (verifiziert: rendert danach weiterhin 1x VSL). Zusätzlich
`snapshotVolumes: false` im Schedule-Template.

## 0h. notjustadevelopercom: ServerSideApply muss gepusht werden

App steht auf `OutOfSync/Missing`, Fehler
`one or more synchronization tasks are not valid (retried 5 times)`.

Ursache: das Chart liefert die velero-CRDs UND Ressourcen, die sie benutzen
(`VolumeSnapshotLocation/default`, `BackupStorageLocation`, `Schedule`). ArgoCDs
client-seitiger Dry-Run kennt die Kinds beim Erst-Sync nicht (velero-CRDs = 0) und
lehnt ab. Im alten Cluster existierten die CRDs seit 323 Tagen — daher nie sichtbar.

Fix liegt in `charts/root-app/templates/notjustadevelopercom.yaml`
(`syncOptions: - ServerSideApply=true`), **wirkt aber erst nach commit + push**:
ArgoCD zieht aus git, nicht aus dem Worktree.

Ohne diesen Schritt kein velero → **kein Restore**. Danach: sealed-secrets-Keys
einspielen (Runbook Schritt 3), dann `velero restore`.

## 0j. Longhorn + NAS-Backup-Target — VORBEREITET, nicht aktiv

Stand 2026-08-07. `modules/longhorn.nix` ist fertig, aber BEWUSST nicht in
`hosts/netcup/netcup.nix` importiert (verifiziert: nicht in services.k3s.manifests,
`services.openiscsi.enable = false`). Longhorn 1.12.0 = neueste stabile Release;
1.12.1 gibt es bisher nur als rc.

**NAS-Seite ist schon fertig.** `nix-config/homelab/modules/features/nas-backup-target.nix`
exportiert `/srv/backup/longhorn` per NFSv4, nur auf dem Mesh-Interface, und der
nas-Host importiert das Modul bereits. Da ist nichts mehr zu bauen.

Drei Blocker, alle im Modulkopf ausführlich dokumentiert:

1. **NixOS-Pfade — longhorn#2166, seit 2021 OFFEN.** Longhorn `nsenter`t in den
   Host-Namespace und erwartet `iscsiadm`/`mount` an FHS-Pfaden. Es gibt bis heute
   keine native Unterstützung. Der von nixpkgs dokumentierte Weg
   (`pkgs/applications/networking/cluster/k3s/docs/examples/STORAGE.md`) schiebt
   allen Longhorn-Pods per **Kyverno-ClusterPolicy** ein PATH-Env unter — also ein
   zusätzlicher Admission-Controller. Alternativen: NixOS-gepatchte Community-Images,
   oder bei local-path bleiben und per nodeSelector pinnen.
   **Das ist eine Architekturentscheidung, keine Fleißarbeit.**
2. **Backup-Target hängt am netbird-Mesh.** `base/_network.nix` hat `mesh.cidr`
   noch als PLATZHALTER (`verified = false`). Ohne Mesh keine Route netcup → NAS,
   also kein Backup-Ziel. Die `backupTarget`-Zeile im Modul ist deshalb
   auskommentiert.
3. **Migration der Bestandsdaten.** postgres 88M, paperless 85M+48M, n8n 26M,
   grocy, signal-api liegen auf local-path. Ein StorageClass-Wechsel migriert
   NICHTS automatisch — pro Volume velero-Restore in eine neue PVC oder manuell
   kopieren.

⚠️ Auf einem Single-Node bringt Longhorn **keinen** Replikationsgewinn. Sinnvoll
wird es erst mit dem Merge (Fleet-Design §5) — vorher nur Overhead.

## 1. bricklink-scraping: weg vom HTML-Scraping, hin zur BrickStore-Lösung

**Status:** aus dem Erst-Deployment ausgeschlossen (`charts/root-app/disabled/`).
**Priorität:** hoch — der Scraper ist derzeit funktionslos.

### Warum

Der aktuelle Ansatz (`code/bricklink-scraping/app/`) holt Store-Inventare über
die interne AJAX-Route
`store.bricklink.com/ajax/clone/store/searchitems.ajax?…&sid=<store>` und
schickt das durch eine Rotation **kostenloser** Proxies, die live von
proxydb.net und free-proxy-list.net gescraped werden.

Das ist am 2026-08-05 verifiziert **kaputt**: `proxies.py`
(`get_proxies_from_proxydb`) liest die Port-Spalte als
`first_col[1].text.strip().split('\n')[0]`. proxydb hat sein HTML geändert,
seitdem entstehen Ports wie `123128`, `121111`, `128080` — alle > 65535.
Ergebnis im Cluster-Log:

```
failed: Failed to parse: http://85.235.150.219:123128. Retrying in 610s...
```

Jeder Request scheitert, der Backoff steigt (377 s → 610 s), es landet **nichts**
mehr in MongoDB. Die 7,55 GB in `store_data` sind Altbestand.

Das ist keine Bug-Fix-Aufgabe: die Fehlerklasse (undokumentierte AJAX-Route +
Gratis-Proxies + HTML-Parsing fremder Seiten) bricht bei jeder Layout-Änderung
auf BrickLink ODER bei jeder Layout-Änderung der Proxy-Listen erneut. Zusätzlich
ist Scraping über Proxy-Rotation gegenüber BrickLinks Nutzungsbedingungen
mindestens grenzwertig.

### Ziel

Auf den Weg umstellen, den **BrickStore** (github.com/rgriebl/brickstore) geht:
offizielle BrickLink-Datenquellen statt HTML-Scraping.

- BrickLinks **offizielle Katalog-Downloads** als Massendaten-Quelle
  (Items/Colors/Categories/Price-Guide) statt Item-für-Item-AJAX.
- Die **BrickLink-API** (OAuth1, Consumer/Token-Paar aus dem Verkäufer-Konto)
  für alles Store-/Order-bezogene.
- Damit entfallen Proxy-Rotation, User-Agent-Spielchen und Backoff-Logik
  komplett — und mit ihnen `proxies.py`, `proxy_manager.py`, `networking.py`.

### Vor der Umsetzung zu klären

- [ ] Bei BrickStore nachlesen, **welche** Endpunkte/Dateien konkret genutzt
      werden und in welcher Kadenz (Katalog-Download vs. API-Call pro Store).
      Nicht raten — BrickStore ist Open Source, die Quelle ist lesbar.
- [ ] Prüfen, ob die offiziellen Quellen die Fragestellung überhaupt abdecken:
      Der heutige Scraper zieht **Inventare fremder Stores** (28 fest verdrahtete
      Store-IDs in `store_inventory.py`). Die BrickLink-API gibt primär Zugriff
      auf den **eigenen** Store. Wenn Wettbewerbsdaten das eigentliche Ziel sind,
      ist womöglich der Price-Guide-Katalog die richtige Quelle, nicht
      Fremd-Store-Inventare — das ändert das Datenmodell.
- [ ] API-Credentials als agenix-Secret anlegen (`secrets/`), nicht als
      SealedSecret im Chart.
- [ ] Entscheiden, ob RabbitMQ überhaupt bleibt: der Cluster läuft mit 10 GiB
      PVC und **195 KB** belegt, es gibt keinen Producer/Consumer im Deployment.
      Ohne Message-Bus fällt auch `rabbitmq-cluster-operator.yml` (336 KB rohe
      Manifeste im Repo) weg.
- [ ] `connection-tester` umbenennen — das Deployment heißt so, führt aber den
      echten Scraper aus (`store_inventory.py`). Irreführend.

### Wiedereinschalten

```sh
cd charts/root-app
git mv disabled/bricklink-scraping.yaml templates/
git mv disabled/mongodb-community-operator.yaml templates/
git mv disabled/ghcr-login-sealed-secret.yaml templates/
git mv disabled/argocd-bricklink-scraping-deploykey-sealed-secret.yaml templates/
# nur falls Message-Bus wirklich gebraucht:
git mv disabled/rabbitmq-cluster-operator.yml templates/
```

Die Daten müssen **nicht** migriert werden (so entschieden am 2026-08-05) — das
Erst-Deployment startet mit leerer MongoDB.

## 2. facter.json fehlt noch

Es gibt bewusst keines im Repo. Das alte stammte vom **Vorgänger-Server**
(`v2202504270128336125.luckysrv.de`, 2025-05-02) und hätte falsche Hardware
beschrieben; das Flake `throw`t nur bei fehlendem, nicht bei veraltetem Report.

Erzeugen beim Install (nur dort läuft nixos-facter mit nix). Gebaut wird auf dem
ZIEL, nicht auf dem Mac — der Mac ist aarch64-**darwin** und kann keine
aarch64-linux-Closure bauen; im kexec-Installer läuft NixOS auf aarch64 mit nix,
6 Kerne / 7,7 GB reichen:

```sh
nixos-anywhere --flake .#netcup --target-host root@v2202505270128345138.powersrv.de \
  --generate-hardware-config nixos-facter ./facter.json \
  --build-on-remote
```

Danach `facter.json` committen und in `hosts/netcup/netcup.nix` den
nixos-facter-Modul-Pfad aktivieren (heute beschreibt das Modul die Hardware
explizit, weil kein gültiger Report existiert).

Bis dahin beschreibt `hosts/netcup/netcup.nix` die Hardware explizit
(Inventar: `~/mschuett-lab-migration/hardware-inventory.json`).

## 3. agenix: netcup-Host-Key als Recipient nachtragen

Die Secrets in `secrets/` sind an `macbook` + `backup` verschlüsselt. Der
netcup-Host kann sie damit **nicht selbst** zur Aktivierungszeit entschlüsseln —
der NixOS-Host-Key existiert erst nach dem ersten Boot.

Nach dem Install:

```sh
ssh root@… cat /etc/ssh/ssh_host_ed25519_key.pub   # -> netcup = "..." in secrets/secrets.nix
cd secrets && nix run github:ryantm/agenix -- -r    # alles neu verschlüsseln
```

Erst danach lässt sich das Einspielen der sealed-secrets-Keys deklarativ machen
(heute Handarbeit, siehe Runbook).

## 4. Sealed-Secrets-Keys VOR dem ersten sealed-secrets-Start einspielen

Reihenfolge-Falle beim Neuaufbau: startet der sealed-secrets-Controller zuerst,
generiert er einen **neuen** Key. Alle SealedSecrets im Repo sind dann
unentschlüsselbar, bis die 11 alten Keys eingespielt und der Controller neu
gestartet wurde.

```sh
agenix -d secrets/sealed-secrets-master-keys.age | kubectl apply -f -
kubectl -n kube-system rollout restart deploy/sealed-secrets
```

## 5. mschuett-lab PUBLIC, nix-config PRIVATE — bewusst so, vorläufig

Entscheidung 2026-08-05: **so akzeptiert**. Ziel ist, dass alles öffentlich wird
(TODO dazu liegt in nix-config). Bis dahin gilt:

- `flake.nix` zieht `base/` aus dem **privaten** `mribrgr/nix-config`. Wer nur
  das öffentliche mschuett-lab klont, kann es nicht evaluieren. Für den Deploy
  irrelevant — gebaut wird mit Zugriff auf beide Repos.
- **mschuett-lab bleibt bewusst PUBLIC.** Privatisieren würde den Bootstrap
  ERSCHWEREN, nicht erleichtern: root-app wird per k3s-Manifest angelegt und
  zieht `https://github.com/mribrgr/mschuett-lab.git` ohne Credentials. Privat
  bräuchte ArgoCD repo-creds, die schon VOR dem ersten Sync existieren müssen —
  also entweder via `nixos-anywhere --extra-files` vorplatziert oder einmal per
  Hand nachgereicht. Als SealedSecret geht es nicht (sealed-secrets läuft zum
  Bootstrap-Zeitpunkt noch nicht).
- Die anderen GitOps-Repos (`steinaberfeinde`, `not-just-a-developer.com`) sind
  ebenfalls public und werden credential-frei gezogen. mschuett-lab privat wäre
  der Sonderfall.
- Öffentliche **Public Keys** im Repo (`users/root.nix`, `secrets/secrets.nix`)
  sind kein Problem: sie sind zum Veröffentlichen gemacht. Die agenix-Rules-Datei
  MUSS im Klartext bleiben, nix liest sie zur Eval-Zeit.
- Was in einem public Infra-Repo wirklich exponiert ist, sind nicht Keys sondern
  **Topologie**: Hostname `v2202505270128345138.powersrv.de`, IP `152.53.15.24`,
  die tls-sans und die Ingress-Hostnames. Recon-Material, kein Credential.
  Mitigation wäre Verschleierung — Aufwand/Nutzen aktuell schlecht.

Falls doch privatisiert wird: `secrets/argocd-legacy-repo-key.age` ist genau der
Deploy-Key dafür (RSA, `mauritius.berger@Mac`), nur die `url` darin zeigt noch auf
`mribrgr/hardware.git` und muss auf `mschuett-lab.git` gehen.

## 6. base/ liegt nur auf einem Branch

Input zeigt auf `git+https://github.com/mribrgr/nix-config?ref=refactor/multiworld-restructure`.
Auf `main` existiert `base/` nicht. Nach dem Merge umstellen auf
`github:mribrgr/nix-config`.

## 7. Aufgeräumt, aber nicht entschieden

- `charts/root-app/disabled/argo-cd.yaml` — ArgoCD verwaltet sich damit selbst.
  Kollidiert mit dem Bootstrap in `modules/argocd.nix` (zwei Verwalter derselben
  Helm-Release). Bleibt deaktiviert, solange der Bootstrap die Quelle ist.
- `gh-hardware.yaml` / `argocd-ssh-key` — Klartext gelöscht, verschlüsselt als
  `secrets/argocd-legacy-repo-key.age`. Wird nur gebraucht, falls mschuett-lab
  doch privat wird (dann braucht ArgoCD wieder repo-creds, siehe Punkt 5).
  Sonst nach verifiziertem Deployment löschen.

**Erledigt 2026-08-05:** xmrig (Monero-Miner) komplett entfernt — Manifeste,
Secret, Wallet-Adresse. Läuft seit 2026-03-27 nicht mehr, Namespace `mining`
existiert nicht. Rest liegt nur noch in 8 Alt-Commits der History (Wallet-Adresse
ist ein öffentlicher Identifier, Pool-Passwort war `worker1` — kein Handlungsbedarf).

## 0k. Node-Ausfall & PV-Verfügbarkeit — Tolerationen gesetzt, Failover offen

**Ausgangsfrage (2026-08-10):** einen Non-Control-Plane-Node verlieren und die PVs
(z. B. der Agents) mit <5 min Downtime auf einem anderen Node wiederhaben.

### Was gemacht ist
`modules/k3s.nix` setzt jetzt `default-not-ready-toleration-seconds=3600` und
`default-unreachable-toleration-seconds=3600` — identisch zu `lab/modules/k3s.nix`.

Das ist **kein** Failover-Feature, sondern Schadensbegrenzung: ohne die Flags gilt
der k8s-Default von 300 s, und ein kurzer k3s-Neustart hätte nach 5 min alle Pods
gelöscht. Genau dieser Ausfall traf das Lab am 2026-07-25; netcup hatte bis
2026-08-10 dieselbe Exposition. Auf einem Single-Node ist Eviction sowieso
sinnlos — es gibt keinen zweiten Node.

### Was NICHT gemacht ist (bewusst)
Kurze `tolerationSeconds` pro Workload. Wirkungslos bis schädlich, solange netcup
allein läuft: Pods würden gelöscht, ohne dass sie irgendwo hin können. Beim Merge
nachziehen — dann pro stateful Workload:

```yaml
tolerations:
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 60
  - key: node.kubernetes.io/unreachable
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 60
```

⚠️ `--kube-apiserver-arg` gilt nur auf dem **Server**. Nach dem Merge ist netcup
Control Plane, also gilt DIESE Datei clusterweit; die Flags in `lab/modules/k3s.nix`
verlieren ihre Wirkung, sobald azure-k3s zum Agent wird. Wer dort etwas erwartet,
sucht an der falschen Stelle.

### Recherche-Ergebnisse zur Storage-Frage (für später)
1. **Longhorn kann NICHT netcup ↔ Azure replizieren.** Die Replikation ist
   synchron; Longhorn-Docs nennen >1 ms Latenz „impractical" und verweisen
   ausdrücklich auf den Backupstore statt auf Cross-Region-Replicas. Longhorn ist
   also nur INNERHALB einer Location sinnvoll, nie über beide Provider.
2. **NAS als zentrales Storage-Backend: verworfen.** Macht eine
   Consumer-Leitung zur harten Abhängigkeit produktiver Workloads, und
   NFS-hard-mounts hängen bei Linkverlust (Prozesse in uninterruptible sleep)
   statt nur langsam zu werden. Fleet-Design §5 hält das schon fest:
   „NAS (kein Node!) nur NFS :2049" — bleibt Backup-Target.
3. **Die Agents haben heute gar keine PVs.** `lab/modules/openclaw.nix` und
   `hermes.nix` enthalten keine einzige PVC. Stateful im Lab sind nur
   `prometheus-data` (local-path), signal-bridge und tenants (je
   `storageClassName: manual`, also statisch). Für den Agent-Fall ist damit
   ausschließlich die Toleranz-/Scheduling-Frage relevant, nicht Storage.
4. **Playground verbietet PVCs bereits per Policy.**
   `lab/modules/playground.nix:337` (ValidatingAdmissionPolicy) erlaubt nur
   `emptyDir/configMap/downwardAPI/projected/secret`; spot-workers sind zusätzlich
   `agent-lab/spot=true:NoSchedule` getaintet. Nicht aufweichen — kein State auf
   preemptible Kapazität ist die richtige Antwort, nicht die Umgehung.

### Wenn HA-Storage wirklich gebraucht wird
Kein Provider-übergreifender Storage-Layer. Stattdessen:
- **Postgres:** CloudNativePG (v1.30.0, 2026-06-29) — asynchrone Streaming-
  Replikation, WAN-tolerant, lokale PVs, Failover in Sekunden.
- **Longhorn:** nur bei 2–3 netcup-VMs in derselben Location (sub-ms). Der Kauf
  brächte zusätzlich etcd-Quorum — heute ist die Control Plane Single-Node, ein
  netcup-Ausfall reißt den Cluster unabhängig von Storage mit. Laut Mauritius
  2026-08-10 **vorerst nicht geplant**, evtl. ferne Zukunft.
- **Stateful in Azure:** Azure Disk CSI, natives Detach/Reattach in der Region.
- Vorher messen: Latenz zwischen netcup-VMs in derselben Location. Longhorns
  Tauglichkeit hängt allein daran. netcup → Azure ist nicht messbar (NSG lässt
  nur 22 inbound), netcup → NAS erst nach dem Mesh (siehe 0j Blocker 2).
