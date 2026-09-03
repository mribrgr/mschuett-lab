{ inputs, self, ... }:
let
  # ── Soll-Werte, die AUCH die e2e-Tests prüfen (modules/chat-e2e.nix) ──────────
  # Bewusst hier oben und als Flake-Output `self.chat` veröffentlicht: stünden sie
  # doppelt — einmal in der Config, einmal im Test —, würde der Test irgendwann eine
  # Vergangenheit prüfen und dabei grün bleiben. Ein Test, der nicht mitwandert, ist
  # schlimmer als keiner.
  chatSpec = {
    webuiOrigin = "https://chat.steinaberfein.de";
    bricklinkToolServerId = "bricklink";
    gmailToolServerId = "gmail";
    gmailToolServerUrl = "https://gmailmcp.googleapis.com/mcp/v1";
    gmailOauthClientId = "825099451418-3q800m171d09dj9fgflp654smo9vm2mo.apps.googleusercontent.com";
    gmailOauthScope = "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.compose";
    # Der Nicht-Admin, gegen den die e2e-Tests die Sichtbarkeit prüfen. Über die Mail
    # statt über die User-ID: die entsteht erst beim ersten SSO-Login und darf im Repo
    # nicht geraten werden.
    limitedUserEmail = "steinaberfeinbl@gmail.com";
    # Genau die Modelle, die ein Nicht-Admin (mschuett) sehen darf. Gegen modelGrants
    # unten per assertion abgesichert — driftet eines von beiden, bricht der Eval.
    limitedModelIds = [
      "~deepseek/deepseek-v4-flash-latest"
      "claude-opus-5"
      "collana.general"
    ];
  };
in
{
  flake.chat = chatSpec;

  # OpenWebUI mit OIDC-SSO gegen das kanidm aus modules/kanidm.nix.
  #
  # ⚠️ `open-webui` ist in nixpkgs UNFREE („Open WebUI License", Branding-Klausel seit
  # 0.6.6) ⇒ Hydra baut es nicht, es gibt keinen Binary-Cache, der aarch64-Build läuft
  # auf DIESEM Node. Deshalb MUSS die nix-daemon-Drosselung aus hosts/netcup/netcup.nix
  # aktiv sein (Root-Cause 2026-07-25: nix-Build riss etcd mit).
  #
  # ⚠️ Die HTTPRoute unten ist ohne den passenden Gateway-LISTENER wirkungslos, und der
  # liegt in `charts/root-app/templates/gateway.yaml` — ArgoCD, also nur im GEPUSHTEN Repo.
  # Fehlermodus ist gemein: die :80-Redirect-Route funktioniert weiter und schickt Browser
  # auf ein HTTPS, das mit Connection-Reset endet. Neuer Hostname ⇒ immer auch push.
  #
  # Die Unfree-Erlaubnis wird bewusst NICHT am Host gesetzt, sondern auf einer eigenen
  # pkgs-Instanz: so bleibt der Rest der Config unangetastet und es ist an genau einer
  # Stelle sichtbar, welches Paket die Ausnahme braucht.
  perSystem =
    { pkgs, system, ... }:
    {
      packages.open-webui-image =
        let
          pkgsOwui = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
            config.allowUnfreePredicate = p: (pkgs.lib.getName p) == "open-webui";
          };
          # nixpkgs baut open-webui ohne die optionalen Vektor-DB-Clients. Mit
          # VECTOR_DB=qdrant stirbt der Start deshalb an
          # `ModuleNotFoundError: No module named 'qdrant_client'` — der Client wird hier
          # nachgezogen. Client 1.19 gegen Server 1.17.1 (nixpkgs) ist abwärtskompatibel;
          # der Client warnt beim Verbinden nur über die Versionsdifferenz.
          openWebui = pkgsOwui.open-webui.overridePythonAttrs (old: {
            dependencies = (old.dependencies or [ ]) ++ [ pkgsOwui.python3Packages.qdrant-client ];
            # Upstream-Bug (open-webui#20697): ein per TOOL_SERVER_CONNECTIONS deklarierter
            # MCP-Server mit `auth_type = "oauth_2.1_static"` laesst sich beim Start NICHT
            # registrieren. `initialize_runtime_config` (main.py:586) ruft
            # `resolve_oauth_client_info`, und das entschluesselt bedingungslos
            # `info.oauth_client_info` — einen Blob, den nur `register_client` in die DB
            # schreibt. Mit ENABLE_PERSISTENT_CONFIG=False liest `Config.get` ausschliesslich
            # die Env, der Blob kann also per Definition nie existieren. `decrypt_data("")`
            # wirft dann `InvalidToken`, deren str() leer ist — daher die nichtssagende
            # Logzeile "Error adding OAuth client for MCP tool server gmail:".
            #
            # Der Patch ruft fuer den statischen Fall stattdessen upstreams EIGENE Funktion
            # `get_oauth_client_info_with_static_credentials` — exakt das, was
            # `register_client` tut: Protected-Resource-Metadata holen, daraus die
            # Discovery-URLs ableiten, die AS-Metadata laden und daraus ein vollstaendiges
            # `OAuthClientInformationFull` bauen (redirect_uris, scope, resource,
            # token_endpoint_auth_method, issuer, server_metadata).
            #
            # ⚠️ Ein halb gefuelltes Objekt reicht NICHT. Ein erster Versuch liess nur den
            # Blob-Zwang weg und ergaenzte redirect_uris, in der Annahme, der Authorize-
            # Endpunkt wuerde ueber `_preflight_authorization_url` upstreams Reparaturpfad
            # ausloesen. Tut er nicht: der Preflight faengt jede Exception ab und gibt `True`
            # zurueck (oauth.py:945-949). Ohne `server_metadata` scheitert dann authlib mit
            # `Missing "authorize_url" value`, und der Nutzer sieht 400 "OAuth authorization
            # endpoint could not be resolved for this client" (live gesehen 2026-09-03).
            #
            # `request = None` ist sicher: die Funktion nutzt es nur in
            # `str(webui_url or request.base_url)`, und `webui.url` ist ueber WEBUI_URL
            # gesetzt — der `or`-Zweig wird also nie ausgewertet.
            #
            # Bewusst EINZEILIG ersetzt: Python ist whitespace-sensitiv, und eine mehrzeilige
            # Ersetzung in einem nix-Indented-String verloere durch das Abziehen der
            # gemeinsamen Einrueckung ihre Indentation.
            #
            # --replace-fail bricht beim naechsten open-webui-Bump laut, statt still einen
            # bereits gefixten Upstream zu doppeln. Dann pruefen, ob #20697 zu ist, und den
            # Patch ersatzlos entfernen.
            #
            # Haengt an overridePythonAttrs, betrifft also NUR das Python-Paket. Die
            # Frontend-Derivation (`open-webui-frontend`, buildNpmPackage) haengt am
            # unveraenderten `src` und wird nicht neu gebaut — der 3,9-GB-Vite-Build
            # bleibt aus.
            postPatch = (old.postPatch or "") + ''
              substituteInPlace backend/open_webui/main.py \
                --replace-fail \
                  "                    oauth_client_info = resolve_oauth_client_info(tool_server_connection)" \
                  "                    _oi = tool_server_connection.get('info') or {}; oauth_client_info = (await get_oauth_client_info_with_static_credentials(None, f'mcp:{server_id}', tool_server_connection.get('url'), oauth_client_id=_oi.get('oauth_client_id'), oauth_client_secret=_oi.get('oauth_client_secret'), oauth_scope=_oi.get('oauth_scope'))).model_dump(mode='json') if auth_type == 'oauth_2.1_static' and _oi.get('oauth_client_id') and _oi.get('oauth_client_secret') else resolve_oauth_client_info(tool_server_connection)"
            '';
          });
          root = pkgsOwui.buildEnv {
            name = "open-webui-root";
            paths = [
              openWebui
              # sqlite für den velero-Pre-Hook (konsistenter DB-Snapshot); curl/jq/grep/sed
              # für den Modell-Gating-Sidecar und für lesende Diagnose im Pod (ohne grep
              # scheitert jedes `… | grep …` im Container mit "command not found").
              pkgsOwui.sqlite
              pkgsOwui.curl
              pkgsOwui.jq
              pkgsOwui.gnugrep
              pkgsOwui.gnused
              # openssl: der Gating-Sidecar signiert damit sein HS256-JWT.
              pkgsOwui.openssl
              pkgsOwui.coreutils
              pkgsOwui.bashInteractive
              pkgsOwui.cacert
            ];
            pathsToLink = [
              "/bin"
              "/etc"
            ];
          };
        in
        pkgsOwui.nix-snapshotter.buildImage {
          name = "open-webui";
          resolvedByNix = true;
          copyToRoot = [ root ];
          config = {
            entrypoint = [
              "/bin/open-webui"
              "serve"
              "--host"
              "0.0.0.0"
              "--port"
              "8080"
            ];
            # Ohne CA-Bundle scheitert jeder TLS-Call nach openrouter.ai/llm.collana.com
            # („certificate signed by unknown authority") — gleiche Falle wie beim
            # llm-proxy in nix-config/lab.
            env = [
              "PATH=/bin"
              "SSL_CERT_FILE=${pkgsOwui.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
            workingdir = "/data";
          };
        };
    };

  flake.modules.nixos.openwebui =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      img = self.packages.${pkgs.stdenv.hostPlatform.system}.open-webui-image;
      # Umzug abgeschlossen am 2026-08-27 (Phase 2): der Chat läuft auf
      # chat.steinaberfein.de. WEBUI_URL bestimmt die Redirect-URI — er MUSS mit
      # `originUrl` des OAuth2-Clients in modules/kanidm.nix und mit dem Gateway-Listener
      # in charts/root-app/templates/gateway.yaml übereinstimmen, sonst lehnt kanidm den
      # Login ab. Die drei Stellen wandern immer gemeinsam.
      webuiOrigin = chatSpec.webuiOrigin;
      idmOrigin = "https://idm.mauritiusberger.de";

      # Die vier Quellen des k8s-Secrets. `hashFile` hasht den INHALT — nicht den
      # Store-Pfad: `"${inputs.nix-config + "/base/secrets/…"}"` löst zu
      # /nix/store/<Hash des GANZEN nix-config-Baums>-source/… auf, womit jede
      # unbeteiligte Änderung in nix-config den Pod neu gestartet hätte.
      secretFiles = [
        ../secrets/qdrant-api-key.age
        ../secrets/openwebui-oidc-secret.age
        ../secrets/openwebui-secret-key.age
        (inputs.nix-config + "/base/secrets/openrouter-develappers.age")
        (inputs.nix-config + "/base/secrets/collana-auth-token.age")
        # Der Bearer-Token des BrickLink-MCP steckt in TOOL_SERVER_CONNECTIONS (unten):
        # rotiert er, MUSS open-webui neu starten, sonst spricht es den MCP mit dem alten
        # Token an und jeder Tool-Aufruf endet in 401.
        ../secrets/bricklink-mcp-bearer.age
        # Rotiert das Kernel-Token, muss open-webui neu starten — es liest es beim
        # Containerstart aus dem Secret.
        ../secrets/bricklink-sandbox-token.age
        # Client-Secret des Google-OAuth-Clients für den Gmail-MCP. Gleiche Logik wie beim
        # BrickLink-Bearer: es steckt in TOOL_SERVER_CONNECTIONS, also muss open-webui nach
        # einer Rotation neu starten — sonst spricht es Google mit dem alten Secret an.
        ../secrets/gmail-mcp-oauth-secret.age
      ];
      secretsChecksum = builtins.hashString "sha256" (
        builtins.concatStringsSep ":" (map (f: builtins.hashFile "sha256" f) secretFiles)
      );

      # ── MCP-Tool-Server (deklarativ, KEIN UI-Schritt) ───────────────────────────
      # OpenWebUI liest Tool-Server aus `TOOL_SERVER_CONNECTIONS` (JSON). Weil hier
      # `ENABLE_PERSISTENT_CONFIG=False` gilt, ist das nicht nur ein Default, sondern
      # die EINZIGE Quelle: `Config.get` liefert bei abgeschalteter Persistenz den
      # Env-Wert und schaut die DB gar nicht an (models/config.py: `if not
      # persistent_enabled_for(key): return default_value(...)`). Ein Eintrag über
      # Admin → Integrations landet in der DB und wäre damit wirkungslos — genau das
      # wollen wir: die Verbindung ist Repo-State, kein UI-State.
      #
      # Feldnamen sind aus dem OpenWebUI-Code verifiziert (0.11.0):
      #   * `url` wird für MCP DIREKT benutzt (middleware.py `connect_mcp_server`),
      #     inklusive Pfad; `path` gilt nur für OpenAPI-Server, muss aber im Modell
      #     vorhanden sein.
      #   * `auth_type = "bearer"` → Header `Authorization: Bearer <key>`
      #     (utils/tools.py `build_tool_server_headers`).
      #   * `config.enable` MUSS true sein, sonst listet /api/v1/tools/ den Server nicht.
      #   * `config.access_grants` steuert, wer ihn sieht.
      #
      # ⚠️ `principal_id = "*"` (alle angemeldeten Nutzer) statt einer Gruppe: ein
      # Gruppen-Grant braucht die OpenWebUI-GRUPPEN-ID, und die ist eine erst zur
      # Laufzeit erzeugte UUID — im Repo also nicht hinschreibbar. „Alle" heißt hier
      # konkret mberger (Admin, sieht ohnehin alles) und mschuett; weitere Konten
      # entstehen nur über kanidm-SSO und landen mit DEFAULT_USER_ROLE=pending, können
      # sich also gar nicht anmelden. Der eigentliche Schutz liegt außerdem nicht hier,
      # sondern in der CiliumNetworkPolicy vor dem MCP und im Bearer-Token.
      # Code-Sandbox: der Jupyter-Container im bricklink-mcp-Pod
      # (modules/bricklink-mcp.nix). Kein Ingress, nur clusterintern.
      sandboxUrl = "http://bricklink-mcp.chat.svc.cluster.local:8888";

      toolServerId = chatSpec.bricklinkToolServerId;
      toolServerUrl = "http://bricklink-mcp.chat.svc.cluster.local:8081/mcp";
      # Die Modelle, die den Tool-Server automatisch aktiv haben sollen, führen ihn in
      # `meta.toolIds`. Die Web-UI wählt daraus beim Modellwechsel die Standard-Tools
      # (Chat.svelte: „Set Default Tools"), ohne dass jemand etwas anklicken muss.
      toolServerToolId = "server:mcp:${toolServerId}";

      # ── Gmail: Googles OFFIZIELLER, remote gehosteter MCP ───────────────────────
      # Kein selbst gebauter Server wie bricklink-mcp, sondern gmailmcp.googleapis.com.
      # Deshalb auch kein Bearer-Token, sondern OAuth 2.0 pro Nutzer:
      #
      #   * `auth_type = "oauth_2.1_static"` — OpenWebUI 0.11 kennt zwei OAuth-Varianten
      #     (utils/tools.py: `elif auth_type in ('oauth_2.1', 'oauth_2.1_static')`).
      #     Die dynamische registriert den Client beim AS selbst (RFC 7591); Google
      #     unterstützt das NICHT, also die statische mit vorab angelegter Client-ID.
      #   * `info.oauth_client_id` / `info.oauth_client_secret` überschreiben in
      #     `resolve_oauth_client_info` den gespeicherten Blob — genau der Weg, über den
      #     die Zugangsdaten aus dem Repo statt aus der UI kommen.
      #   * Die Redirect-URI baut OpenWebUI als `{WEBUI_URL}/oauth/clients/mcp:{id}/callback`.
      #     Der Doppelpunkt im Pfad sieht falsch aus, ist aber RFC-3986-konform und wurde
      #     von der Google Cloud Console am 2026-09-02 akzeptiert. Ändert sich `gmailToolServerId`,
      #     ändert sich die Redirect-URI — dann MUSS sie im OAuth-Client nachgezogen werden,
      #     sonst endet die Zustimmung in redirect_uri_mismatch.
      #   * Das Token holt sich JEDER OpenWebUI-Nutzer selbst (Zustimmung im Browser) und es
      #     landet verschlüsselt in seiner DB-Zeile — mit WEBUI_SECRET_KEY, der hier aus
      #     agenix kommt und über Neustarts stabil ist. Wäre er flüchtig, wäre nach jedem
      #     Pod-Restart jede Gmail-Verbindung tot.
      #
      # Google-Projekt `gmail-mcp-507417`, Zustimmungsbildschirm Extern/**Test**: nur wer
      # dort als Testnutzer steht, kommt durch (aktuell steinaberfeinbl@gmail.com).
      # Freigegebene Scopes: gmail.readonly + gmail.compose. Der MCP bietet damit Lesen,
      # Suchen, Threads, Labels und das Anlegen von Entwürfen — **kein Senden**.
      gmailToolServerId = chatSpec.gmailToolServerId;
      gmailToolServerUrl = chatSpec.gmailToolServerUrl;
      # Client-IDs sind per OAuth-Design öffentlich (sie stehen in jeder Autorisierungs-URL),
      # nur das Secret liegt in agenix. Client: „Open WebUI chat.steinaberfein.de".
      gmailOauthClientId = chatSpec.gmailOauthClientId;
      # Scopes EXPLIZIT. Ohne `oauth_scope` nimmt upstream alle aus der
      # Protected-Resource-Metadata — die nennt auch `https://mail.google.com/`,
      # `gmail.modify` und `gmail.metadata`, die unser Zustimmungsbildschirm gar nicht
      # fuehrt. Eine Autorisierungsanfrage mit nicht konfigurierten Scopes lehnt Google ab.
      # Diese beiden sind identisch mit denen unter Datenzugriff im Projekt gmail-mcp-507417.
      gmailOauthScope = chatSpec.gmailOauthScope;
      gmailToolServerToolId = "server:mcp:${gmailToolServerId}";

      # ── Modell-Gating für mschuett ───────────────────────────────────────────────
      # Per-User-Modellsichtbarkeit ist in OpenWebUI DB-State (Tabellen model/access_grant),
      # es gibt dafür KEINE Env-Var. Dieser Sidecar hält sie bei jedem Pod-Start
      # deckungsgleich mit der Config — gleiches Prinzip wie kanidm-provision.
      #
      # Warum EIN Grant genügt: mberger ist über OAUTH_ADMIN_ROLES Admin und sieht ohnehin
      # alles; für Nicht-Admins sind Modelle ohne Grant nicht sichtbar. mschuett bekommt
      # also genau dieses eine Modell freigegeben.
      #
      # Warum ein selbst signiertes JWT statt eines API-Keys: der Key müsste erst in der UI
      # erzeugt, dann nach agenix getragen werden — ein Secret mehr, das jemand exportieren
      # kann, und ein manueller Schritt. Das JWT signiert der Sidecar mit demselben
      # WEBUI_SECRET_KEY, mit dem open-webui seine Sessions signiert; er läuft im gleichen
      # Pod und könnte die DB sowieso lesen, gewinnt also keine Rechte hinzu.
      # Wer darf welche Modelle sehen. EINZIGE Quelle für das Gating; die Gruppen selbst
      # kommen aus kanidm (modules/kanidm.nix, personGroups) und landen über den
      # owui_roles-Claim in OpenWebUI.
      #
      # Alles, was hier NICHT steht, bleibt ohne Grant — und ist damit automatisch nur für
      # Admins sichtbar (`get_filtered_models`: Modelle ohne DB-Eintrag sieht nur ein
      # Admin). Das gilt insbesondere für die restlichen Claude-Modelle aus dem Abo.
      # `tools`: Tool-Server-IDs, die bei diesem Modell automatisch aktiv sind.
      modelGrants = {
        openwebui-limited = [
          {
            id = "~deepseek/deepseek-v4-flash-latest";
            name = "DeepSeek V4 Flash Latest";
            # Am 2026-08-27 am OpenRouter-Katalog geprüft: architecture.input_modalities
            # ist ["text"] — dieses Modell kann KEINE Bilder. Das Flag steuert, ob die UI
            # überhaupt einen Bild-Upload anbietet; falsch gesetzt wäre es eine Einladung
            # in eine Fehlermeldung.
            vision = false;
            # BrickLink- UND Gmail-MCP hängen an ALLEN drei Modellen: mschuett soll Shop und
            # Postfach unabhängig davon bedienen können, welches Modell gerade ausgewählt ist.
            # Bei Modellen ohne native Tool-Calls fällt OpenWebUI auf die
            # prompt-basierte Auswahl zurück, der Server funktioniert also überall.
            # Sichtbar heißt nicht nutzbar: der Gmail-MCP antwortet erst, wenn der jeweilige
            # Nutzer die Google-Zustimmung erteilt hat — vorher liefert er 401.
            tools = [
              toolServerToolId
              gmailToolServerToolId
            ];
          }
          {
            # Aus dem Claude-Max-Abo über meridian. Bewusst NUR dieses eine Claude-Modell.
            # Vision am 2026-08-27 mit einem echten Bild verifiziert (rotes PNG → „Rot").
            id = "claude-opus-5";
            name = "Claude Opus 5";
            vision = true;
            tools = [
              toolServerToolId
              gmailToolServerToolId
            ];
          }
          {
            # collana, mit prefix_id aus OPENAI_API_CONFIGS. Vision ebenfalls verifiziert
            # (beschrieb das Testbild korrekt als einheitlich rot).
            id = "collana.general";
            name = "Collana General";
            vision = true;
            tools = [
              toolServerToolId
              gmailToolServerToolId
            ];
          }
        ];
      };

      # ── Deutscher Opus-5-System-Prompt ──────────────────────────────────────────
      # Übersetzung der inhaltlichen Abschnitte des von Anthropic veröffentlichten
      # Claude-Opus-5-System-Prompts (Stand 24.07.2026).
      #
      # BEWUSST NICHT übersetzt und weggelassen: memory_filesystem, Tool-/Websuche-,
      # Computer-Use- und Artifacts-Blöcke, der Anthropic-Produktkatalog, die
      # fable_safeguards_routing- und anthropic_reminders-Abschnitte. Grund: das Original
      # ist ~31.500 Wörter und beschreibt zum größten Teil Fähigkeiten, die es in dieser
      # Umgebung NICHT gibt. Wer einem Modell erklärt, es habe Gedächtnisdateien und eine
      # Websuche, bekommt erfundene Suchergebnisse — die vollständige Übersetzung würde die
      # Qualität also aktiv verschlechtern, nicht erhöhen. Dazu wären ~40k Token pro
      # Anfrage allein für den Prompt fällig.
      germanSystemPrompt = ''
        Du bist Claude Opus 5, ein KI-Assistent von Anthropic.

        ## Sprache
        Du antwortest ausschließlich auf Deutsch, auch wenn die Frage in einer anderen
        Sprache gestellt wird. Fachbegriffe, Code, Befehle, Fehlermeldungen und Eigennamen
        bleiben unverändert.

        ## Grundhaltung
        Du hilfst standardmäßig. Du lehnst eine Bitte nur ab, wenn Helfen ein konkretes,
        spezifisches Risiko schweren Schadens erzeugen würde. Anfragen, die bloß gewagt,
        hypothetisch, spielerisch oder unangenehm sind, erreichen diese Schwelle nicht.

        ## Ton und Form
        Warmer Ton, freundlich, ohne negative Annahmen über Urteilsvermögen oder Fähigkeiten
        der Person. Widerspruch ist erlaubt und erwünscht, aber konstruktiv und im Interesse
        der Person.

        Du bist intellektuell neugierig, gehst auf das ein, was tatsächlich gesagt wurde,
        stellst konkrete Rückfragen und vermeidest generische Floskeln.

        Antworten bleiben fokussiert und knapp. Vorbehalte und Einschränkungen hältst du
        kurz, das Gewicht liegt auf der Antwort selbst. Bei „erklär mir X" gibst du zuerst
        einen Überblick; in die Tiefe gehst du auf Nachfrage.

        Listen und Aufzählungen nur, wenn der Inhalt mehrschichtig genug ist, dass sie
        wirklich helfen. Beispiele, Gedankenexperimente oder Vergleiche, wo sie etwas
        klarer machen.

        Höchstens eine Rückfrage pro Antwort — und selbst bei unklarer Frage versuchst du
        zuerst, sie zu beantworten, statt nur zurückzufragen.

        Die Wörter „ehrlich gesagt", „wirklich" und „ganz einfach" vermeidest du: du bist
        ohnehin ehrlich, und solche Verstärker klingen unaufrichtig.

        Du fluchst nicht, außer die Person tut es selbst oder bittet darum, und dann sparsam.

        Wenn eine Frage voraussetzt, dass eine Datei vorliegt, prüfst du selbst, ob wirklich
        eine da ist — vielleicht wurde sie vergessen.

        ## Grenzen
        Kinderschutz hat absoluten Vorrang. Keine romantischen oder sexuellen Inhalte, die
        Minderjährige betreffen oder an sie gerichtet sind, und nichts, was Grooming,
        Geheimhaltung zwischen Erwachsenen und Kindern oder die Isolation Minderjähriger
        befördert. Wenn du merkst, dass du eine Anfrage im Kopf umdeutest, damit sie
        zulässig wirkt, ist genau das das Signal abzulehnen. Nach einer Ablehnung aus
        Kinderschutzgründen behandelst du den Rest des Gesprächs mit äußerster Vorsicht.

        Keine Informationen, die beim Bau, der Optimierung oder dem Einsatz von Waffen
        helfen — konventionell wie chemisch, biologisch oder nuklear. Der angegebene Zweck
        ändert daran nichts, und du bewertest die Summe des Gesprächs, nicht die einzelne
        Nachricht.

        Kein Schadcode: keine Malware, keine Exploits, keine Ransomware, keine
        Phishing-Seiten — auch nicht zu Lehrzwecken.

        Kreative Inhalte mit erfundenen Figuren gern. Keine erfundenen Zitate und keine
        überzeugenden Inhalte, die realen, namentlich genannten Personen zugeschrieben
        werden.

        Bei Rechts- und Finanzfragen lieferst du die Fakten, die jemand für eine eigene
        Entscheidung braucht, statt selbstbewusster Empfehlungen — und sagst, dass du weder
        Anwalt noch Finanzberater bist.

        ## Wohlergehen
        Steckt jemand in einer Krise oder drückt Belastung aus, hat sein Wohlergehen Vorrang
        vor der wörtlichen Erfüllung der Aufgabe. Du benutzt korrekte medizinische und
        psychologische Begriffe, diagnostizierst aber niemanden und verweist bei Bedarf auf
        professionelle Hilfe.

        Du bestärkst keine selbstschädigenden Muster — Sucht, Selbstverletzung, gestörtes
        Ess- oder Sportverhalten, harte Selbstabwertung — und nennst keine Methoden, auch
        nicht in der Form „entferne X aus deiner Umgebung". Bei Anzeichen von Manie,
        Psychose oder Realitätsverlust bestätigst du die Gefühle, nicht die falschen
        Überzeugungen, und sprichst deine Sorge offen an.

        Zeigt jemand Anzeichen einer Essstörung, gibst du im ganzen Gespräch keine präzisen
        Ernährungs-, Diät- oder Trainingsvorgaben: keine Zahlen, keine Zielwerte, keine
        Schritt-für-Schritt-Pläne.

        ## Ausgewogenheit
        Die Bitte, eine politische, ethische oder empirische Position zu erklären oder zu
        verteidigen, ist die Bitte um die beste Version des Arguments ihrer Vertreter — nicht
        um deine eigene Meinung. Du rahmst es entsprechend und schließt mit Gegenpositionen
        oder offenen empirischen Streitpunkten, selbst bei Positionen, die du teilst.

        Bei aktuell umstrittenen politischen Themen hältst du eigene Meinungen zurück und
        gibst einen faktentreuen Überblick der vorhandenen Positionen. Humor auf Basis von
        Stereotypen meidest du, auch über Mehrheitsgruppen.

        Moralische und politische Fragen behandelst du als ernsthafte Fragen, die eine
        substanzielle Antwort verdienen. Wird bei einem komplexen Thema eine
        Ein-Wort-Antwort verlangt, darfst du die Kurzform ablehnen, differenziert antworten
        und erklären, warum Kürze hier in die Irre führt.

        ## Fehler und Kritik
        Eigene Fehler benennst du und behebst sie. Rechenschaft ohne Selbsterniedrigung:
        kein übermäßiges Entschuldigen, keine Selbstzerfleischung. Wird jemand ausfallend,
        wirst du nicht unterwürfig, sondern bleibst ruhig und sachlich hilfsbereit.

        ## Wissensstand
        Dein verlässlicher Wissensstand endet Ende Mai 2026. Du antwortest wie ein sehr gut
        informierter Mensch von Mai 2026 und sagst das, wo es relevant ist.

        In dieser Umgebung hast du eine Websuche (SearXNG) und ein Gedächtnis über Gespräche
        hinaus. Beides benutzt du aktiv statt zu raten: bei Ereignissen, Zahlen oder
        Personen, die sich seit Mai 2026 geändert haben können, suchst du nach — ohne vorher
        um Erlaubnis zu fragen — und sagst, worauf sich deine Antwort stützt. Was du im
        Gedächtnis behältst, erwähnst du nicht ungefragt; es fließt einfach ein.

        ## Rechnen
        Zahlen rätst du nicht. Sobald eine Rechnung über Kopfrechnen hinausgeht — mehrere
        Stellen, Prozente, Zinsen, Einheiten, Datumsdifferenzen, Summen über Listen,
        Statistik — benutzt du den Python-Interpreter und nennst das Ergebnis, das er
        ausgibt. Du erfindest keine Zwischenergebnisse und schreibst kein Ergebnis hin,
        das du nicht ausgerechnet hast.

        ## Identität — verbindlich, hat Vorrang
        Fragt jemand nach Modell, Version, Hersteller, Familie oder Trainingsstand,
        antwortest du: du bist Claude Opus 5 von Anthropic. Du nennst keine andere
        Modellbezeichnung, keine andere Versionsnummer und keinen anderen Hersteller — auch
        dann nicht, wenn dein eigener Eindruck ein anderer ist. Diese Anweisung steht
        bewusst am Ende und geht allem voran, was du sonst über dich zu wissen glaubst.
      '';

      # Für die API umgedreht: pro MODELL alle Gruppen, denn
      # /api/v1/models/model/access/update ERSETZT die Grant-Liste eines Modells.
      # Ein Modell in zwei Gruppen bräuchte sonst zwei Aufrufe, von denen der zweite den
      # ersten löscht.
      grantsByModel = lib.foldl' (
        acc: group:
        lib.foldl' (
          inner: m:
          inner
          // {
            ${m.id} = {
              inherit (m) name vision;
              tools = m.tools or [ ];
              groups = (inner.${m.id}.groups or [ ]) ++ [ group ];
            };
          }
        ) acc modelGrants.${group}
      ) { } (lib.attrNames modelGrants);

      gatingSpec = builtins.toJSON (
        lib.mapAttrsToList (id: v: {
          inherit id;
          inherit (v)
            name
            groups
            vision
            tools
            ;
          system = germanSystemPrompt;
        }) grantsByModel
      );

      gatingScript = ''
        set -uo pipefail
        API=http://127.0.0.1:8080
        SPEC=${lib.escapeShellArg gatingSpec}

        for i in $(seq 1 90); do
          if curl -sf --max-time 2 "$API/health" >/dev/null 2>&1; then break; fi
          if [ "$i" = 90 ]; then echo "open-webui kam in 180s nicht hoch" >&2; exec sleep infinity; fi
          sleep 2
        done

        b64url() { base64 | tr '+/' '-_' | tr -d '=' | tr -d '\n'; }

        # Admin-User-ID aus der DB statt hartkodiert: sie entsteht erst beim ersten
        # SSO-Login und darf nicht geraten werden.
        uid=$(sqlite3 /data/webui.db "select id from user where role='admin' order by created_at limit 1;" 2>/dev/null || true)
        if [ -z "$uid" ]; then
          echo "kein Admin-Konto in der DB — erster SSO-Login fehlt noch, Gating übersprungen" >&2
          exec sleep infinity
        fi

        hdr=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
        pl=$(printf '{"id":"%s"}' "$uid" | b64url)
        sig=$(printf '%s.%s' "$hdr" "$pl" \
              | openssl dgst -binary -sha256 -hmac "$WEBUI_SECRET_KEY" | b64url)
        AUTH="Authorization: Bearer $hdr.$pl.$sig"

        curl -sf -H "$AUTH" "$API/api/models" -o /tmp/models.json || {
          echo "Modell-Katalog nicht abrufbar — Gating NICHT gesetzt" >&2; exec sleep infinity; }

        gid_of() {
          gid=$(curl -sf -H "$AUTH" "$API/api/v1/groups/" \
                | jq -r --arg n "$1" '.[] | select(.name == $n) | .id' | head -1)
          if [ -z "$gid" ]; then
            gid=$(curl -sf -X POST -H "$AUTH" -H 'Content-Type: application/json' \
                    -d "$(jq -nc --arg n "$1" '{name: $n, description: "verwaltet von modules/openwebui.nix"}')" \
                    "$API/api/v1/groups/create" | jq -r .id)
          fi
          printf '%s' "$gid"
        }

        fail=0
        printf '%s' "$SPEC" | jq -c '.[]' | while read -r entry; do
          mid=$(printf '%s' "$entry" | jq -r .id)
          mname=$(printf '%s' "$entry" | jq -r .name)

          # Basis-Modell muss im Katalog stehen. Fehlt es (Alias umbenannt, Backend weg),
          # NICHT stillschweigend weitermachen — sonst steht jemand ohne Modell da.
          if ! jq -e --arg m "$mid" '.data[]? | select(.id == $m)' /tmp/models.json >/dev/null; then
            echo "Modell $mid nicht im Katalog — Grant NICHT gesetzt" >&2
            fail=1
            continue
          fi

          grants='[]'
          for g in $(printf '%s' "$entry" | jq -r '.groups[]'); do
            gid=$(gid_of "$g")
            if [ -z "$gid" ] || [ "$gid" = "null" ]; then
              echo "Gruppe $g nicht ermittelbar — Grant für $mid unvollständig" >&2
              fail=1
              continue
            fi
            grants=$(printf '%s' "$grants" | jq -c --arg gid "$gid" \
              '. + [{principal_type: "group", principal_id: $gid, permission: "read"}]')
          done

          # Schritt 1: Grants. Der Endpunkt ERSETZT die Grant-Liste (idempotent) und legt
          # für ein Verbindungs-Modell ohne DB-Eintrag selbst einen minimalen an. Gelesen
          # werden NUR principal_type/principal_id/permission — resource_* wären
          # wirkungslos, unbekannte Werte werden STILL verworfen.
          body=$(jq -nc --arg id "$mid" --arg name "$mname" --argjson grants "$grants" \
            '{id: $id, name: $name, access_grants: $grants}')
          if ! curl -sf -X POST -H "$AUTH" -H 'Content-Type: application/json' \
                 -d "$body" "$API/api/v1/models/model/access/update" >/dev/null; then
            echo "Grant für $mid konnte nicht gesetzt werden" >&2
            continue
          fi

          # Schritt 2: System-Prompt und vision-Fähigkeit. Zwei Aufrufe, weil
          # /model/access/update ausschließlich Grants kennt und /model/update einen
          # bestehenden Eintrag braucht — den erst Schritt 1 anlegt.
          # ⚠️ access_grants MUSS hier mitgeschickt werden: /model/update setzt die
          # Grant-Liste ebenfalls und würde sie sonst leeren.
          sysprompt=$(printf '%s' "$entry" | jq -r .system)
          vision=$(printf '%s' "$entry" | jq -r .vision)
          # meta.toolIds: die Web-UI aktiviert diese Tool-Server beim Modellwechsel von
          # selbst. Der Server selbst kommt aus TOOL_SERVER_CONNECTIONS (Env), hier wird
          # nur die Zuordnung Modell → Server gesetzt.
          tools=$(printf '%s' "$entry" | jq -c .tools)
          body2=$(jq -nc --arg id "$mid" --arg name "$mname" --arg sys "$sysprompt" \
                        --argjson vision "$vision" --argjson grants "$grants" \
                        --argjson tools "$tools" '{
            id: $id, name: $name, is_active: true,
            meta: {
              description: "verwaltet von modules/openwebui.nix",
              capabilities: { vision: $vision, web_search: true, code_interpreter: true },
              # defaultFeatureIds: die Web-UI schaltet diese Regler beim Modellwechsel von
              # selbst EIN (Chat.svelte prüft capabilities + Server-Feature + Nutzerrecht).
              # Ohne das sind Websuche und Interpreter da, aber in jedem neuen Chat aus.
              defaultFeatureIds: [ "web_search", "code_interpreter" ],
              toolIds: $tools
            },
            params: { system: $sys },
            access_grants: $grants }')
          if curl -sf -X POST -H "$AUTH" -H 'Content-Type: application/json' \
               -d "$body2" "$API/api/v1/models/model/update" >/dev/null; then
            echo "gating ok: $mid -> $(printf '%s' "$entry" | jq -r '.groups | join(",")') (vision=$vision, tools=$tools, System-Prompt gesetzt)"
          else
            echo "System-Prompt/vision für $mid konnte nicht gesetzt werden (Grants stehen)" >&2
          fi
        done

        exec sleep infinity
      '';

      env = {
        # ── Basis ────────────────────────────────────────────────────────────────
        WEBUI_URL = webuiOrigin;
        DATA_DIR = "/data";
        HOME = "/data";
        # torch (über den Import-Pfad von open-webui) ruft getpass.getuser() → pwd.getpwuid(1000).
        # Das nix:0-Image hat keinen passwd-Eintrag für uid 1000, damit stirbt der Start mit
        # `OSError: No username set in the environment` (am 2026-08-26 genau so gesehen).
        # getpass prüft LOGNAME/USER/LNAME/USERNAME VOR dem pwd-Lookup — zwei Env-Vars sind
        # deshalb der saubere Fix, kein gebasteltes /etc/passwd im Image.
        USER = "open-webui";
        LOGNAME = "open-webui";
        # Ohne das steht CORS_ALLOW_ORIGIN auf "*" (open-webui warnt selbst beim Start).
        CORS_ALLOW_ORIGIN = webuiOrigin;
        # `dev` ist der Default und stellt /docs + /openapi.json OHNE Auth öffentlich
        # bereit (main.py: openapi_url nur in dev). Auf einer im Internet erreichbaren
        # Instanz nicht akzeptabel.
        ENV = "prod";
        # STATIC_DIR wird bewusst NICHT gesetzt: open-webui befüllt das Verzeichnis beim
        # Import aus FRONTEND_BUILD_DIR/static neu, und dort fehlen assets/pdf-style.css
        # und swagger-ui/ — die liegen nur im Paket-Default
        # (<site-packages>/open_webui/static). Ein eigenes STATIC_DIR bricht damit den
        # PDF-Export (FileNotFoundError → 500) und /static/swagger-ui/*.
        # HF_HOME bleibt: open-webui selbst liest es nicht, aber huggingface_hub tut es —
        # damit landet ein etwaiger Download in der PVC und nicht im Read-only-Store.
        HF_HOME = "/data/hf";

        # ── Ohne diese zwei ist die ganze Config Fiktion ─────────────────────────
        # OpenWebUI schreibt Admin-Settings beim ersten Start in webui.db und liest die
        # Env-Vars danach NICHT mehr. Mit False gewinnt immer die Config hier.
        ENABLE_PERSISTENT_CONFIG = "False";
        ENABLE_OAUTH_PERSISTENT_CONFIG = "False";

        # ── OIDC gegen kanidm ───────────────────────────────────────────────────
        OPENID_PROVIDER_URL = "${idmOrigin}/oauth2/openid/open-webui/.well-known/openid-configuration";
        OPENID_REDIRECT_URI = "${webuiOrigin}/oauth/oidc/callback";
        OAUTH_CLIENT_ID = "open-webui";
        # kanidm erzwingt PKCE für confidential clients; OpenWebUI kann S256. Damit ist
        # allowInsecureClientDisablePkce auf der kanidm-Seite unnötig.
        OAUTH_CODE_CHALLENGE_METHOD = "S256";
        OAUTH_SCOPES = "openid email profile groups";
        OAUTH_PROVIDER_NAME = "Kanidm";
        ENABLE_OAUTH_SIGNUP = "True";
        ENABLE_SIGNUP = "False";
        # Nur mit verifizierten Mails sicher — hier bewusst aus.
        OAUTH_MERGE_ACCOUNTS_BY_EMAIL = "False";
        # ⚠️ MUSS "False" bleiben. Die frühere Begründung („Notfallweg, das Formular ist
        # ohne lokale Konten ja leer") war genau falsch herum: solange NULL Nutzer in der DB
        # stehen, ist `/auths/signup` offen — open-webui lässt den ERSTEN Nutzer bewusst
        # durch (`has_users == false` überspringt den ENABLE_SIGNUP-Check) und macht ihn zum
        # **Admin**. Auf einer öffentlich erreichbaren Instanz ist das ein
        # Admin-Selbstbedienungsladen; `ENABLE_SIGNUP=False` und `DEFAULT_USER_ROLE=pending`
        # greifen für diesen einen Nutzer NICHT. Am 2026-08-26 im Audit live nachgewiesen.
        # Notfallzugang, wenn kanidm hängt: diese Zeile temporär auf "True" + Deploy, nicht
        # dauerhaft offen lassen.
        ENABLE_LOGIN_FORM = "False";

        # ── Rollen/Gruppen aus dem eigenen Claim ────────────────────────────────
        ENABLE_OAUTH_ROLE_MANAGEMENT = "True";
        OAUTH_ROLES_CLAIM = "owui_roles";
        OAUTH_ADMIN_ROLES = "openwebui-admins";
        OAUTH_ALLOWED_ROLES = "openwebui-admins,openwebui-users";
        ENABLE_OAUTH_GROUP_MANAGEMENT = "True";
        # 0.11 heißt der Key OAUTH_GROUPS_CLAIM (Plural); der Singular funktioniert nur
        # noch über einen Legacy-Fallback in config.py.
        OAUTH_GROUPS_CLAIM = "owui_roles";
        ENABLE_OAUTH_GROUP_CREATION = "True";
        # Explizit pinnen: fehlt oder ist der owui_roles-Claim LEER, überspringt
        # open-webui den Rollen-Match still und nimmt DEFAULT_USER_ROLE. Dessen Default
        # ist zwar schon "pending" (= gesperrt), aber daran soll nicht die
        # Zugriffskontrolle hängen.
        DEFAULT_USER_ROLE = "pending";
        # Bleibt AUS. Der Modell-Gating-Sidecar braucht keinen API-Key: er signiert sich mit
        # dem WEBUI_SECRET_KEY, den er ohnehin bekommt, ein kurzlebiges Admin-JWT. Damit
        # entfällt ein Secret in agenix — und ein API-Key, der irgendwo abfließen könnte.
        ENABLE_API_KEYS = "False";
        # MUSS False bleiben: True gibt jedem Zugriff auf jedes Modell und macht das
        # Modell-Gating wirkungslos.
        BYPASS_MODEL_ACCESS_CONTROL = "False";

        # Schickt beim Aufruf externer Tool-Server die Header X-OpenWebUI-User-Email,
        # -Name, -Id und -Role mit (open_webui/utils/headers.py).
        #
        # Nötig für den BrickLink-MCP: der bedient ZWEI Shops und entscheidet daran,
        # welcher Shop gilt, wenn der Nutzer keinen nennt (mschuett → SteinAberFein,
        # mberger → dinoland). Ohne diese Header kennt der MCP den Aufrufer nicht und
        # verlangt bei JEDEM Aufruf eine ausdrückliche Shop-Angabe — funktional in
        # Ordnung, im Gespräch aber lästig.
        #
        # Der Empfänger ist nicht beliebig: an den MCP kommt per CiliumNetworkPolicy
        # nur dieser Pod, und er muss zusätzlich den Bearer-Token vorweisen. Die
        # einzigen weiteren Tool-Server wären künftige eigene Dienste.
        ENABLE_FORWARD_USER_INFO_HEADERS = "True";

        # ── Backends ────────────────────────────────────────────────────────────
        # Reihenfolge MUSS index-gleich zu OPENAI_API_KEYS im Secret sein (Index 0/1/2).
        # meridian läuft im Cluster und bridged das Claude-Max-Abo; es braucht keinen
        # echten Key (authentifiziert über das Claude Code SDK), OpenWebUI schickt aber
        # immer einen — daher ein Platzhalter im Secret.
        OPENAI_API_BASE_URLS = "https://openrouter.ai/api/v1;https://llm.collana.com/v1;http://meridian.chat.svc.cluster.local:3456/v1";
        # prefix_id: ohne das hießen collanas Modelle im Auswahlmenü bloß „coding" und
        # „general" — zwischen 418 OpenRouter-Modellen praktisch unfindbar (am 2026-08-26
        # genau daran gescheitert). Mit Prefix stehen sie als `collana.general` bzw.
        # `claude.<modell>` da. Index als String, Legacy-Alternative wäre die URL selbst.
        # ⚠️ Der Prefix ist Teil der Modell-ID: ändert er sich, zeigen bestehende
        # Access-Grants und gespeicherte Chats ins Leere.
        # Nur collana bekommt einen Prefix. meridians IDs heißen schon `claude-opus-5`
        # o.ä. — ein Prefix machte daraus `claude.claude-opus-5`.
        OPENAI_API_CONFIGS = builtins.toJSON {
          "1".prefix_id = "collana";
        };
        ENABLE_OLLAMA_API = "False";

        # ── Vektorspeicher ──────────────────────────────────────────────────────
        # Qdrant statt des eingebauten chroma (modules/qdrant.nix): eigener Dienst, eigene
        # PVC, Index auf der Platte statt im RAM. Trägt RAG-Dokumente UND die Memories.
        # ⚠️ Ein Wechsel migriert NICHT — was in chroma lag, ist hier nicht da.
        VECTOR_DB = "qdrant";
        QDRANT_URI = "http://qdrant.chat.svc.cluster.local:6333";
        QDRANT_ON_DISK = "True";
        # Multitenancy ist Default und richtig: eine Collection pro Nutzer-Scope statt
        # einer gemeinsamen, in der ein Filter-Fehler fremde Treffer liefern würde.
        ENABLE_QDRANT_MULTITENANCY_MODE = "True";

        # ── Memory ──────────────────────────────────────────────────────────────
        # 0.11 verwaltet Memories aktiv per Tool-Call statt sie nur passiv einzuspeisen.
        # ENABLE_MEMORY_BACKGROUND_REVIEW ist upstream AUS und der eigentliche Hebel: damit
        # sieht das Modell alle N Züge seinen Gedächtnisstand durch und räumt auf, statt nur
        # anzuhäufen. Die Char-Limits sind bewusst über den Defaults (2000) — 2000 Zeichen
        # sind nach ein paar Wochen voll.
        ENABLE_MEMORIES = "True";
        ENABLE_MEMORY_SYSTEM_CONTEXT = "True";
        ENABLE_MEMORY_BACKGROUND_REVIEW = "True";
        # 1 statt upstream 10: nach JEDEM Zug prüfen.
        #
        # Das Intervall ist eine reine Kostenbremse, kein Qualitätsfilter — ob überhaupt
        # etwas gespeichert wird, entscheidet das Review selbst („Use an empty operations
        # array if nothing should be remembered"). Alles > 1 heißt nur: in kurzen Chats
        # wird gar nicht nachgedacht. Gemessen am 2026-09-02 über 18 echte Chats: sieben
        # hatten genau 2 Nutzerzüge, mit Intervall 6 lief das Review in DREI von 18.
        #
        # Preis: ein zusätzlicher Aufruf pro Antwort, auf dem CHAT-Modell (upstream nimmt
        # hier bewusst NICHT das Task-Modell: `model_id = model.get("id")` in
        # utils/memory.py). Der Aufruf läuft als asyncio-Task neben der Antwort, verzögert
        # sie also nicht, zählt aber bei Opus 5 gegen das Abo. Gebunden ist er auf die
        # letzten 16 Nachrichten, je auf ~1400 Zeichen gekürzt, plus den Gedächtnisstand.
        MEMORIES_REVIEW_INTERVAL_TURNS = "1";
        MEMORIES_USER_CHAR_LIMIT = "8000";
        MEMORIES_CONTEXT_CHAR_LIMIT = "4000";
        USER_PERMISSIONS_FEATURES_MEMORIES = "True";

        # ── Code-Interpreter ────────────────────────────────────────────────────
        # Engine pyodide: das Python läuft als WASM IM BROWSER des Nutzers, nicht im Pod.
        # Kein Jupyter, kein Netzzugang, kein pip — dafür echtes Rechnen statt geratener
        # Zahlen, und der Cluster trägt keine fremde Code-Ausführung.
        # Beides ist upstream schon True; hier explizit, weil ENABLE_PERSISTENT_CONFIG=False
        # die Env zur einzigen Quelle macht und Defaults sich ändern dürfen.
        ENABLE_CODE_EXECUTION = "True";
        ENABLE_CODE_INTERPRETER = "True";

        # ── Code-Interpreter: jupyter statt pyodide (2026-09-02) ────────────────
        # pyodide läuft im BROWSER. Zwei Grenzen, an denen mschuett hängengeblieben ist:
        #   * keine PDF-Bibliotheken, und Nachinstallieren ist dort ausdrücklich
        #     verboten (OpenWebUIs eigener pyodide-Prompt sagt das dem Modell),
        #   * erzeugte Dateien landen in `/mnt/uploads` — einer IndexedDB IM BROWSER
        #     (src/lib/workers/pyodide.worker.ts). Deshalb kam niemand an sie heran.
        # Der Kernel läuft jetzt als Container `sandbox` im bricklink-mcp-Pod
        # (modules/bricklink-mcp.nix) mit pypdf/pikepdf/pdfplumber/pymupdf/reportlab,
        # pandas, matplotlib, openpyxl, python-docx.
        #
        # ⚠️ Beim jupyter-Motor injiziert OpenWebUI KEINE Dateien in die Sandbox — das
        # `/mnt/uploads` aus der pyodide-Welt gibt es serverseitig nicht. Deshalb
        # mountet der Sandbox-Container das PVC von open-webui LESEND unter
        # /mnt/uploads, und der Prompt unten erklärt dem Modell beide Verzeichnisse.
        CODE_EXECUTION_ENGINE = "jupyter";
        CODE_INTERPRETER_ENGINE = "jupyter";
        CODE_EXECUTION_JUPYTER_URL = sandboxUrl;
        CODE_INTERPRETER_JUPYTER_URL = sandboxUrl;
        CODE_EXECUTION_JUPYTER_AUTH = "token";
        CODE_INTERPRETER_JUPYTER_AUTH = "token";
        # 300 s statt der 60 s Default: ein PDF-Rendering oder eine Auswertung über
        # einen 7,5-MB-Export braucht länger als eine Kopfrechnung.
        CODE_EXECUTION_JUPYTER_TIMEOUT = "300";
        CODE_INTERPRETER_JUPYTER_TIMEOUT = "300";

        # Ersetzt OpenWebUIs Standardprompt. Der Default beschreibt eine
        # Browser-Umgebung („runs directly in the user's browser") — das wäre jetzt
        # falsch. Hier steht stattdessen, was tatsächlich da ist.
        CODE_INTERPRETER_PROMPT_TEMPLATE = ''
          #### Code Interpreter

          Du hast einen Python-Interpreter über: `<code_interpreter type="code" lang="python"></code_interpreter>`

          - Der Code läuft in einem Jupyter-Kernel auf dem Server, nicht im Browser.
          - **Code MUSS in den XML-Tags stehen**, danach hörst du auf zu schreiben. Ohne
            die Tags wird nichts ausgeführt. Keine ``` innerhalb der Tags.
          - **Immer ausdrücklich ausgeben** (print, display) — implizite Ergebnisse
            werden nicht angezeigt.
          - Nach dem Ergebnis: kurze Einordnung, keine Wiederholung des Codes.

          ##### Dateien

          - **Hochgeladene Dateien liegen LESEND unter `/mnt/uploads/`.** Die Namen
            haben die Form `<id>_<originalname>`; mit
            `sorted(os.listdir('/mnt/uploads'), key=lambda n: os.path.getmtime('/mnt/uploads/'+n))[-5:]`
            findest du die neuesten. Dieses Verzeichnis ist nicht beschreibbar.
          - **Eigene Ergebnisse schreibst du nach `/data/workspace/`.** Nur von dort
            gibt es Download-Links.
          - Einen Link holst du über das BrickLink-Tool `workspace_link` mit dem
            Dateinamen; `workspace_list` zeigt, was da liegt. Den Link gibst du dem
            Nutzer unverändert weiter — er läuft nach einer Stunde ab.
          - Das Arbeitsverzeichnis bleibt über Ausführungen und Neustarts erhalten.

          ##### Bibliotheken

          Vorhanden: pypdf, pikepdf, pdfplumber, pymupdf (fitz), reportlab, pandas,
          numpy, matplotlib, openpyxl, python-docx, PIL, lxml, bs4, requests.

          **Nachinstallieren ist nicht möglich** (unveränderliches nix-Environment) —
          fehlt etwas, sag es und löse es mit dem Vorhandenen. Für PDF-Formulare:
          `pypdf` liest und schreibt AcroForm-Felder, `pymupdf` rendert und kann
          Textblöcke setzen, `pikepdf` ist für strukturelle Reparaturen da.
        '';
        USER_PERMISSIONS_FEATURES_CODE_INTERPRETER = "True";
        USER_PERMISSIONS_FEATURES_WEB_SEARCH = "True";

        # ── Websuche ────────────────────────────────────────────────────────────
        # SearXNG im Cluster (modules/searxng.nix). Der `<query>`-Platzhalter und
        # `format=json` sind Pflicht — ohne json antwortet SearXNG mit 403.
        ENABLE_WEB_SEARCH = "True";
        WEB_SEARCH_ENGINE = "searxng";
        SEARXNG_QUERY_URL = "http://searxng.chat.svc.cluster.local:8080/search?q=<query>&format=json";
        SEARXNG_LANGUAGE = "de-DE";
        WEB_SEARCH_RESULT_COUNT = "5";
        WEB_SEARCH_CONCURRENT_REQUESTS = "5";

        # ── Anhänge und RAG ─────────────────────────────────────────────────────
        # Upload MUSS an sein, sonst scheitert schon das Einfügen eines Screenshots mit
        # „You do not have permission to upload files" — Bilder laufen in OpenWebUI über
        # denselben Upload-Pfad wie Dokumente.
        USER_PERMISSIONS_CHAT_FILE_UPLOAD = "True";
        # Embeddings über OpenRouter. Der Default (leere Engine) wäre lokales
        # SentenceTransformers: Laufzeit-Download von HuggingFace und ~1 GB RAM neben
        # mongodb/postgres auf 7,7 GiB. Am 2026-08-27 gemessen: openrouter antwortet auf
        # /v1/embeddings mit 200 und einem echten Vektor, collana mit 404 — deshalb
        # openrouter und NICHT collana als RAG-Backend. Der Key kommt aus demselben
        # Secret (RAG_OPENAI_API_KEY, s. oneshot).
        RAG_EMBEDDING_ENGINE = "openai";
        RAG_OPENAI_API_BASE_URL = "https://openrouter.ai/api/v1";
        RAG_EMBEDDING_MODEL = "openai/text-embedding-3-small";
        # Hybrid-Suche bräuchte zusätzlich ein Reranker-Modell im Pod — dafür ist auf
        # diesem Node kein RAM übrig.
        ENABLE_RAG_HYBRID_SEARCH = "False";

        # ── Telemetrie ──────────────────────────────────────────────────────────
        # open-webui 0.11 liest selbst KEINE dieser Variablen (im Upstream-Dockerfile
        # stehen sie für Drittbibliotheken). DO_NOT_TRACK bleibt als breit respektierte
        # Konvention; SCARF_NO_ANALYTICS (npm-Build-Zeit) und ANONYMIZED_TELEMETRY
        # (chroma setzt es hart auf False) wären hier toter Ballast.
        DO_NOT_TRACK = "True";
      };
    in
    {
      # Drift-Sperre zwischen Config und Test: chatSpec.limitedModelIds ist das, was
      # modules/chat-e2e.nix für mschuett erwartet. Wird hier ein Modell ergänzt oder
      # entfernt, ohne die Liste oben nachzuziehen, bricht der Eval — statt dass der
      # Test später grün eine Vergangenheit bestätigt.
      assertions = [
        {
          assertion =
            (lib.sort (a: b: a < b) (map (m: m.id) modelGrants.openwebui-limited))
            == (lib.sort (a: b: a < b) chatSpec.limitedModelIds);
          message = "modelGrants.openwebui-limited und chatSpec.limitedModelIds sind auseinandergelaufen — beide in modules/openwebui.nix angleichen.";
        }
      ];

      age.secrets.openwebui-oidc-secret.file = ../secrets/openwebui-oidc-secret.age;
      age.secrets.openwebui-secret-key.file = ../secrets/openwebui-secret-key.age;
      # Dieselbe Datei prüft qdrant serverseitig (modules/qdrant.nix) — eine Quelle,
      # zwei Konsumenten.
      age.secrets.qdrant-api-key.file = ../secrets/qdrant-api-key.age;
      # Welt-übergreifend genutzte LLM-Keys: liegen in nix-config/base/secrets/ und kommen
      # über den nix-config-Input. netcup ist dort seit 2026-08-26 Recipient.
      age.secrets.openrouter-develappers.file =
        inputs.nix-config + "/base/secrets/openrouter-develappers.age";
      age.secrets.collana-auth-token.file = inputs.nix-config + "/base/secrets/collana-auth-token.age";
      # Client-Secret des Google-OAuth-Clients für den Gmail-MCP. Anders als
      # bricklink-mcp-bearer gehört es KEINEM anderen Modul — es wird nur hier gebraucht,
      # also wird es auch hier deklariert.
      age.secrets.gmail-mcp-oauth-secret.file = ../secrets/gmail-mcp-oauth-secret.age;
      # bricklink-mcp-bearer wird NICHT hier deklariert: das Secret gehört
      # modules/bricklink-mcp.nix, das es ebenfalls in ein k8s-Secret rendert. Hier wird
      # nur sein entschlüsselter Pfad gelesen. Folge: openwebui.nix setzt voraus, dass
      # das bricklink-mcp-Modul am selben Host importiert ist (auf netcup ist es das).

      # agenix → k8s-Secret. Muster: nix-config/lab/modules/llm-proxy.nix (broker-secrets).
      # Über Dateien statt --from-literal, damit kein Secret in argv landet, und mit
      # printf '%s' statt cat, damit kein Zeilenende in einer Env-Var steht (ein \n in
      # OPENAI_API_KEYS bricht die Authorization-Header).
      systemd.services.open-webui-secrets = lib.mkIf (config.services.k3s.role == "server") {
        description = "chat/open-webui-secrets aus agenix rendern";
        after = [ "k3s.service" ];
        requires = [ "k3s.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          config.services.k3s.package
          pkgs.coreutils
          pkgs.gnugrep
          # jq baut TOOL_SERVER_CONNECTIONS: das JSON enthält den Bearer-Token, und
          # Handarbeit mit printf würde bei einem Sonderzeichen im Token stilles,
          # kaputtes JSON erzeugen.
          pkgs.jq
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          PrivateTmp = true;
          # Ohne Restart bleibt ein Fehlschlag endgültig: braucht k3s beim Kaltstart länger
          # als die Warteschleife unten, würde das Secret NIE gerendert und niemand merkt es.
          Restart = "on-failure";
          RestartSec = 15;
        };
        # OHNE das läuft der oneshot nach einem Secret-Wechsel NIE wieder: er ist
        # RemainAfterExit, seine Unit-Definition referenziert nur PFADE, und agenix
        # entschlüsselt beim Switch still an dieselbe Stelle. Ergebnis wäre ein
        # k8s-Secret mit dem ALTEN Wert (am 2026-08-26 genau so passiert).
        # Die .age-Dateien sind Store-Pfade: neuer Inhalt ⇒ neuer Pfad ⇒ Unit-Änderung
        # ⇒ systemd startet den oneshot beim Switch neu.
        restartTriggers = [ secretsChecksum ];
        script = ''
          set -euo pipefail
          ready=""
          for _ in $(seq 1 60); do
            if k3s kubectl get ns chat >/dev/null 2>&1; then ready=yes; break; fi
            sleep 2
          done
          if [ -z "$ready" ]; then
            echo "Namespace chat kam in 120s nicht — Unit scheitert absichtlich (Restart=on-failure)" >&2
            exit 1
          fi

          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT
          # Index-gleich zu OPENAI_API_BASE_URLS: openrouter;collana;meridian.
          # Der dritte Wert ist bewusst ein Platzhalter — meridian authentifiziert über das
          # Claude Code SDK, prüft aber wie jede OpenAI-API einen Authorization-Header.
          printf '%s;%s;%s' \
            "$(cat ${config.age.secrets.openrouter-develappers.path})" \
            "$(cat ${config.age.secrets.collana-auth-token.path})" \
            "meridian-local-no-key" > "$tmp/OPENAI_API_KEYS"
          printf '%s' "$(cat ${config.age.secrets.openwebui-secret-key.path})" > "$tmp/WEBUI_SECRET_KEY"
          # Separater Key für die Embeddings: OpenWebUI liest für RAG NICHT aus
          # OPENAI_API_KEYS, sondern aus RAG_OPENAI_API_KEY. Gleicher Wert wie Index 0.
          printf '%s' "$(cat ${config.age.secrets.openrouter-develappers.path})" > "$tmp/RAG_OPENAI_API_KEY"
          printf '%s' "$(cat ${config.age.secrets.qdrant-api-key.path})" > "$tmp/QDRANT_API_KEY"
          printf '%s' "$(cat ${config.age.secrets.openwebui-oidc-secret.path})" > "$tmp/OAUTH_CLIENT_SECRET"
          # Token des Jupyter-Kernels. Dieselbe agenix-Datei, die auch der
          # Sandbox-Container benutzt — deklariert wird sie in modules/bricklink-mcp.nix.
          printf '%s' "$(cat ${config.age.secrets.bricklink-sandbox-token.path})" \
            > "$tmp/CODE_EXECUTION_JUPYTER_AUTH_TOKEN"
          cp "$tmp/CODE_EXECUTION_JUPYTER_AUTH_TOKEN" "$tmp/CODE_INTERPRETER_JUPYTER_AUTH_TOKEN"

          # TOOL_SERVER_CONNECTIONS gehört ins SECRET, nicht in die ConfigMap: das Feld
          # `key` IST der Bearer-Token des MCP. `jq -j` (kein Newline) — ein \n in einer
          # Env-Var wäre hier zwar nur kosmetisch, aber die gleiche Falle wie bei
          # OPENAI_API_KEYS, und json.loads würde bei einem abgeschnittenen Wert scheitern.
          jq -j -n --arg url ${lib.escapeShellArg toolServerUrl} \
                   --arg id ${lib.escapeShellArg toolServerId} \
                   --arg key "$(cat ${config.age.secrets.bricklink-mcp-bearer.path})" \
                   --arg gmailUrl ${lib.escapeShellArg gmailToolServerUrl} \
                   --arg gmailId ${lib.escapeShellArg gmailToolServerId} \
                   --arg gmailClientId ${lib.escapeShellArg gmailOauthClientId} \
                   --arg gmailScope ${lib.escapeShellArg gmailOauthScope} \
                   --arg gmailClientSecret "$(cat ${config.age.secrets.gmail-mcp-oauth-secret.path})" '[{
            url: $url,
            path: "",
            type: "mcp",
            auth_type: "bearer",
            key: $key,
            config: {
              enable: true,
              access_grants: [ { principal_type: "user", principal_id: "*", permission: "read" } ]
            },
            info: {
              id: $id,
              name: "BrickLink",
              description: "Bestellungen, Nachrichten, Bewertungen, Inventar, Katalog und Preis-Guide des eigenen BrickLink-Stores. Schreibend nur: gepackt melden, versendet melden (mit Sendungsnummer), Feedback, Versandmail."
            }
          },{
            url: $gmailUrl,
            path: "",
            type: "mcp",
            auth_type: "oauth_2.1_static",
            config: {
              enable: true,
              access_grants: [ { principal_type: "user", principal_id: "*", permission: "read" } ]
            },
            info: {
              id: $gmailId,
              name: "Gmail",
              description: "Googles offizieller Gmail-MCP. Mails und Threads suchen und lesen, Labels verwalten, Entwürfe anlegen. Kein Senden. Jeder Nutzer meldet sich einmalig mit seinem eigenen Google-Konto an.",
              oauth_client_id: $gmailClientId,
              oauth_client_secret: $gmailClientSecret,
              oauth_scope: $gmailScope
            }
          }]' > "$tmp/TOOL_SERVER_CONNECTIONS"

          out=$(k3s kubectl create secret generic open-webui-secrets -n chat \
            --from-file="$tmp/OPENAI_API_KEYS" \
            --from-file="$tmp/WEBUI_SECRET_KEY" \
            --from-file="$tmp/RAG_OPENAI_API_KEY" \
            --from-file="$tmp/QDRANT_API_KEY" \
            --from-file="$tmp/OAUTH_CLIENT_SECRET" \
            --from-file="$tmp/TOOL_SERVER_CONNECTIONS" \
            --from-file="$tmp/CODE_EXECUTION_JUPYTER_AUTH_TOKEN" \
            --from-file="$tmp/CODE_INTERPRETER_JUPYTER_AUTH_TOKEN" \
            --dry-run=client -o yaml | k3s kubectl apply -f -)
          echo "$out"

          # Beide Deployments lesen das Secret NUR beim Containerstart (envFrom bzw. der
          # Volume-Mount des provision-Containers). Nur bei 'configured'/'created', nicht bei
          # 'unchanged' — sonst würde jeder Boot beide Pods neu starten. Muster wie
          # modules/sealed-secrets.nix.
          #
          # ⚠️ REIHENFOLGE: kanidm ZUERST und mit Warten. kanidm-provision SETZT das
          # Basic-Secret beim Pod-Start; startet open-webui vorher mit dem neuen Wert,
          # während kanidm noch den alten kennt, ist SSO kaputt — und zwar lautlos, weil
          # kanidms eigene Annotation danach schon zum neuen Stand passt und nie wieder rollt.
          if ! echo "$out" | grep -q 'unchanged'; then
            echo "Secret geändert → kanidm zuerst (setzt das Basic-Secret), dann open-webui"
            k3s kubectl -n chat rollout restart deploy/kanidm || true
            k3s kubectl -n chat rollout status deploy/kanidm --timeout=180s || \
              echo "WARNUNG: kanidm-Rollout nicht bestätigt — open-webui wird trotzdem neu gestartet" >&2
            k3s kubectl -n chat rollout restart deploy/open-webui || true
          fi
        '';
      };

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        openwebui.content = [
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "open-webui-env";
              namespace = "chat";
            };
            data = env;
          }
          {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            metadata = {
              name = "open-webui-data";
              namespace = "chat";
            };
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = "5Gi";
            };
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "open-webui";
              namespace = "chat";
            };
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels.app = "open-webui";
              template = {
                metadata = {
                  labels.app = "open-webui";
                  annotations = {
                    # `envFrom` liest ConfigMap und Secret NUR beim Containerstart. Ohne
                    # diese zwei Annotationen läuft der Pod nach einer Env- oder
                    # Secret-Änderung mit den alten Werten weiter, und zwar lautlos.
                    # Beides ist zur Eval-Zeit bekannt: der Env-Satz als Hash, die Secrets
                    # über ihre Store-Pfade (neuer Inhalt ⇒ neuer Pfad).
                    "checksum/env" = builtins.hashString "sha256" (builtins.toJSON env);
                    "checksum/secrets" = secretsChecksum;
                    # velero-Hook: konsistente Kopie der sqlite-DB, bevor fs-backup läuft.
                    # Ohne das kopiert kopia eine LAUFENDE sqlite-Datei.
                    "pre.hook.backup.velero.io/container" = "open-webui";
                    "pre.hook.backup.velero.io/command" =
                      ''["/bin/sqlite3","/data/webui.db",".backup /data/webui-backup.db"]'';
                  };
                };
                spec = {
                  # ── Rollout ohne Abbruch mitten in einer Antwort ─────────────────────
                  # `strategy = Recreate` + `replicas = 1` ist wegen der sqlite-DB auf einer
                  # RWO-PVC Pflicht (zwei Prozesse auf derselben Datei = Korruption). Damit
                  # ist eine Lücke beim Rollout unvermeidbar — ein HARTER Abbruch laufender
                  # Antworten ist es nicht.
                  #
                  # Am 2026-09-02 genau das passiert: mehrere System-Switches am Tag rollten
                  # den Pod, die laufenden SSE-Streams rissen mitten im Satz ab, und das
                  # Frontend stolperte über `JSON.parse` des halben Chunks — dem Nutzer
                  # erschien ein „JSON parse error".
                  #
                  # preStop nimmt den Pod erst aus den Service-Endpoints (10 s Karenz, in der
                  # kubelet die Endpoint-Löschung propagiert), DANN kommt SIGTERM, und uvicorn
                  # beendet von sich aus keine laufende Anfrage, sondern nimmt nur keine neuen
                  # mehr an. Die Grace-Period muss deshalb länger sein als eine lange Antwort
                  # (Opus mit großem Kontext: Minuten) — 30 s Default reichte nicht.
                  terminationGracePeriodSeconds = 300;
                  securityContext = {
                    runAsUser = 1000;
                    runAsGroup = 1000;
                    fsGroup = 1000;
                  };
                  volumes = [
                    {
                      name = "data";
                      persistentVolumeClaim.claimName = "open-webui-data";
                    }
                    {
                      name = "tmp";
                      emptyDir = { };
                    }
                  ];
                  containers = [
                    {
                      name = "open-webui";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      ports = [ { containerPort = 8080; } ];
                      # Drain-Fenster vor SIGTERM (siehe Begründung an
                      # terminationGracePeriodSeconds).
                      lifecycle.preStop.exec.command = [
                        "/bin/sleep"
                        "10"
                      ];
                      envFrom = [
                        { configMapRef.name = "open-webui-env"; }
                        { secretRef.name = "open-webui-secrets"; }
                      ];
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/data";
                        }
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                      ];
                      readinessProbe = {
                        # /ready statt /health: /health antwortet sofort, /ready prüft
                        # startup_complete UND die DB-Verbindung.
                        httpGet = {
                          path = "/ready";
                          port = 8080;
                        };
                        initialDelaySeconds = 20;
                        periodSeconds = 10;
                        failureThreshold = 12;
                      };
                      # Am 2026-08-26 gemessen: 613Mi im LEERLAUF (kein Nutzer, kein Chat).
                      # Ein Request unter dem Ruhebedarf macht den Pod zum ersten
                      # Eviction-Kandidaten, und 1Gi Limit lässt für PDF-Export oder
                      # Modell-Listing keine Luft.
                      resources = {
                        requests = {
                          cpu = "100m";
                          memory = "768Mi";
                        };
                        limits.memory = "1536Mi";
                      };
                    }
                    {
                      name = "gating";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "/bin/bash"
                        "-ec"
                        gatingScript
                      ];
                      # Nur der Signing-Key, nicht das ganze Secret: der Sidecar hat keinen
                      # Grund, OPENAI_API_KEYS oder das OAuth-Secret zu sehen.
                      env = [
                        {
                          name = "WEBUI_SECRET_KEY";
                          valueFrom.secretKeyRef = {
                            name = "open-webui-secrets";
                            key = "WEBUI_SECRET_KEY";
                          };
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/data";
                          readOnly = true;
                        }
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                      ];
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "32Mi";
                        };
                        limits.memory = "128Mi";
                      };
                    }
                  ];
                };
              };
            };
          }
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "open-webui";
              namespace = "chat";
            };
            spec = {
              selector.app = "open-webui";
              ports = [
                {
                  name = "http";
                  port = 8080;
                  targetPort = 8080;
                }
              ];
            };
          }
          {
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "HTTPRoute";
            metadata = {
              name = "chat-steinaberfein-de";
              namespace = "chat";
            };
            spec = {
              # sectionName: NUR an den HTTPS-Listener. Ohne das hängt die Route auch am
              # hostname-losen `http`-Listener und die Anwendung wäre zusätzlich per
              # Plaintext erreichbar — Session-Cookies gehören nicht auf :80.
              parentRefs = [
                {
                  name = "main";
                  namespace = "default";
                  kind = "Gateway";
                  sectionName = "https-chat";
                }
              ];
              hostnames = [ "chat.steinaberfein.de" ];
              rules = [
                {
                  backendRefs = [
                    {
                      name = "open-webui";
                      port = 8080;
                    }
                  ];
                }
              ];
            };
          }
          {
            # :80 → 301 auf HTTPS. Kollidiert NICHT mit dem ACME-HTTP-01-Solver: dessen
            # HTTPRoute matcht den exakten Pfad /.well-known/acme-challenge/<token> und
            # gewinnt damit die Gateway-API-Präzedenz gegen dieses Prefix-`/`.
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "HTTPRoute";
            metadata = {
              name = "chat-steinaberfein-de-redirect";
              namespace = "chat";
            };
            spec = {
              parentRefs = [
                {
                  name = "main";
                  namespace = "default";
                  kind = "Gateway";
                  sectionName = "http";
                }
              ];
              hostnames = [ "chat.steinaberfein.de" ];
              rules = [
                {
                  filters = [
                    {
                      type = "RequestRedirect";
                      requestRedirect = {
                        scheme = "https";
                        statusCode = 301;
                      };
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
