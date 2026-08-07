{
  # root-Zugang der mschuett-lab-Hosts.
  #
  # Der Key steht literal HIER, weil er hierher gehört: eine Host-Config
  # deklariert, wer sich einloggen darf. Das ist kein Duplikat von
  # nix-config/mac/modules/ssh-client.nix — dort steht ein PRIVATE-Key-PFAD
  # (`~/.ssh/id_ed25519`), hier der zugehörige PUBLIC KEY. Verschiedene Werte,
  # also nichts zu deduplizieren.
  #
  # Der Weg über die nixosConfiguration der anderen Welten (damit ssh-client sich
  # ableiten könnte) ist bewusst versperrt: er würde alle Welten-Locks in einen
  # Eval ziehen, was nix-config/flake.nix explizit ausschließt.
  #
  # KONVENTION für neue Keys: `~/.ssh/id_<name>` auf der Client-Seite.
  #
  # Seit 2026-08-07 nur noch EIN Key. Der zweite (`id_netcup_max_1`, RSA) war die
  # Rückfalltür für den Cutover, solange die Box noch Ubuntu fuhr. Der NixOS-Host
  # akzeptiert macbook-agenix, verifiziert mit
  #   ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 root@152.53.15.24
  # → damit ist die Rückfalltür raus (zusammen mit dem Alias `netcup_max_1` in
  # nix-config/mac/modules/ssh-client.nix).
  flake.modules.nixos.user-root = _: {
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICxGWKrG3PlTZxWzW071IxUEUbJfr6lXQqHC0m+uDdiK macbook-agenix"
    ];
  };
}
