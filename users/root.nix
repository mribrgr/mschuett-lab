{
  # root-Zugang der mschuett-lab-Hosts.
  #
  # Die Keys stehen literal HIER, weil sie hierher gehören: eine Host-Config
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
  # ZWEI Keys, damit der Neuaufbau nicht aussperrt:
  #   1. macbook-agenix — die Flotten-Adminidentität, zugleich agenix-Recipient.
  #      Nach dem Cutover der einzige nötige Key.
  #   2. id_netcup_max_1 — Rückfalltür, solange die Box noch Ubuntu fährt (sie
  #      akzeptiert nur diesen). Aus dem privaten Key abgeleitet, die .pub fehlte
  #      lokal. Nach dem Cutover ersatzlos löschen, zusammen mit dem Alias
  #      `netcup_max_1` in ssh-client.nix.
  #
  # HINWEIS: der ssh-rsa-Key aus dem alten configuration.nix war ein DRITTER,
  # heute nirgends mehr vorhandener Key (Vorgänger-Server) — absichtlich NICHT
  # übernommen.
  flake.modules.nixos.user-root = _: {
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICxGWKrG3PlTZxWzW071IxUEUbJfr6lXQqHC0m+uDdiK macbook-agenix"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCtt+dzmUej4D7aQFmuNZo/2Y4UuBOe/cwjnEhX05nPYohDFYGJNkSVWy5H5EVpj4L+LFHwdkw5b7SSFG/IRB8jrND9XtFaVHaGxH4P/74HLgE3Tsyb3cIT9B/afEWfaPOGAOg0ZQRMI8i9acDBaQ4MyTkbqJh6LXM4yCK9y5gTeMKHzO5jZOsT97DdvPBsmtBFE8QDMsqZJmmjD0Dh4QXOeKWnb2kbhhJceXnpX5L1e8JsWdEpSCaIlhqMoxJCSmEGJSmN8MelmzYMl+nH9YZcZ+UwBy1Bwlpvqd/4kTmWycGhrLYmw8XPIzwEaGN8D2qorTcd2xvpkRZ6x2Z/6UP3NsOE4XQXl8qBGC5YdXHe31hu4cQXXiy3k7B+10nVEBDO97SLPoPnbRJx41FSlgQA8pKCaX7Day9ndA5vSvIEiqlTkOkzHhVFV3+SdyaFhGK1DeRNOMXGiVJ0TSxoXVUA7yAJPYaRWv6g/OrXD25lDvXjK/kNbkDqTcO2N3hnKwE7rGvoi5RWEmnbQki5ZbWgB7noXYUOz6EWLu5BnaDRTlUDE+YKHLsDAyX75XHMQjZna0lTCaeQqIzxT122mQuoZsswmF4cIZkSCpZ5AM+k3GPNzvsWER2kzvac7gdB7K2WNWHaOncxAxKnHDQcibtLkbQTM3Y6fLJ6xvNjGX2/fQ== id_netcup_max_1"
    ];
  };
}
