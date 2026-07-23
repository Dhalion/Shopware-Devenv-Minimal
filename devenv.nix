{ pkgs, inputs, lib, config, ... }:
# Clean Symfony-Flex Shopware 6 dev environment (open source), tuned for local development.
# Docs: https://developer.shopware.com/docs/guides/installation/devenv.html
let
  # ─── Single source of truth for the project domain ─────────────────────────
  # Change this ONE value per project; the Caddy vhost, APP_URL and Cypress base
  # URL below all follow it. (The Shopware *package* version lives in composer.json
  # under shopware/core — the other bundles follow it via "*".)
  project = "shopware-template";
  host = "${project}.localhost";
in {
  packages = [
    pkgs.gnupatch                                           # for composer patches
    inputs.froshpkgs.packages.${pkgs.system}.shopware-cli   # optional Shopware CLI helper
  ];

  dotenv.disableHint = true;

  languages.javascript = {
    enable = lib.mkDefault true;
    package = lib.mkDefault pkgs.nodejs_24;
  };

  languages.php.enable = true;
  languages.php.version = "8.4";
  languages.php.extensions = [ "amqp" "redis" "grpc" "xdebug" "pdo_mysql" "mysqli" "zstd" "apcu" ];
  languages.php.ini = ''
    memory_limit = 2048M
    max_execution_time = 3600
    pdo_mysql.default_socket = ''${MYSQL_UNIX_PORT}
    mysqli.default_socket = ''${MYSQL_UNIX_PORT}
    realpath_cache_size = 8M
    realpath_cache_ttl = 3600
    session.gc_probability = 0
    session.save_handler = redis
    session.save_path = "tcp://127.0.0.1:6379/0"
    display_errors = On
    error_reporting = E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED

    ; OPcache — Balance: bigger cache, but timestamps still validated so edited
    ; files are picked up immediately (no manual cache clear needed in dev).
    opcache.enable_cli = 1
    opcache.memory_consumption = 512M
    opcache.interned_strings_buffer = 32
    opcache.max_accelerated_files = 100000
    opcache.validate_timestamps = 1
    opcache.revalidate_freq = 0
    opcache.jit = tracing
    opcache.jit_buffer_size = 256M

    ; APCu — used by composer's apcu-autoloader and available as a fast local
    ; object cache for the app (see README for composer config apcu-autoloader).
    apc.enable_cli = 1

    zend.assertions = 0
    short_open_tag = 0
    zend.detect_unicode = 0

    ; Xdebug is OFF by default so plain CLI calls (console commands, tests, composer
    ; scripts) pay zero overhead. It is turned on selectively:
    ;   - web requests: via the FPM pool's env[XDEBUG_MODE] below (Cookie/trigger)
    ;   - CLI:          via `debug-console <command>` or XDEBUG_MODE=debug XDEBUG_TRIGGER=1
    xdebug.mode = off
    xdebug.start_with_request = trigger
    xdebug.discover_client_host = false
    xdebug.client_host = 127.0.0.1
    xdebug.client_port = 9003
  '';

  languages.php.fpm.pools.web = {
    settings = {
      "clear_env" = "no";
      # Dev = single user, no need to scale workers up/down — static avoids the
      # dynamic pool's warm-up latency on the first requests after idle.
      "pm" = "static";
      "pm.max_children" = 10;
      "request_terminate_timeout" = "0";
      # Only the FPM pool (i.e. web requests) enables Xdebug — CLI stays off.
      # Actual triggering is still gated by xdebug.start_with_request=trigger
      # (browser extension cookie / XDEBUG_TRIGGER), so normal browsing has no cost.
      "env[XDEBUG_MODE]" = "debug";
    };
  };

  # On-demand CLI debugging: `debug-console bin/console some:command` enables
  # Xdebug (mode + trigger) for that single invocation only. Plain `php bin/console
  # ...` stays fast (xdebug.mode=off above).
  scripts.debug-console.exec = ''
    XDEBUG_MODE=debug XDEBUG_TRIGGER=1 exec php "$@"
  '';

  services.caddy.enable = lib.mkDefault true;
  services.caddy.virtualHosts."http://${host}" = {
    extraConfig = ''
      root * public
      php_fastcgi unix/${config.languages.php.fpm.pools.web.socket}
      file_server
    '';
  };

  services.mysql = {
    enable = true;
    package = pkgs.mysql84;
    initialDatabases = lib.mkDefault [{ name = "shopware"; }];
    ensureUsers = lib.mkDefault [
      {
        name = "shopware";
        password = "shopware";
        ensurePermissions = { "*.*" = "ALL PRIVILEGES"; };
      }
    ];
    settings = {
      mysqld = {
        group_concat_max_len = 320000;
        max_allowed_packet = "128M";
        sql_mode = "STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION";

        # ═══════════════════════════════════════════════════════════════════════
        # Dev performance tuning — LOCAL ONLY, never use these in production.
        # Durability is deliberately traded for speed: this DB is disposable and
        # can be recreated in minutes via `devenv tasks run shop:install`.
        # ═══════════════════════════════════════════════════════════════════════

        # Keep the whole working set in RAM (default 128M makes migrations disk-bound).
        # Sized for this machine's 31G RAM — lower this in devenv.local.nix on smaller boxes.
        innodb_buffer_pool_size = "4G";
        innodb_buffer_pool_instances = 4;

        # Large redo log + buffer → write-heavy migrations checkpoint far less often.
        innodb_redo_log_capacity = "1G";
        innodb_log_buffer_size = "64M";

        # Durability OFF: no fsync on commit, no double-write protection. Biggest
        # speed lever for write-heavy migrations/imports. Risk: an OS crash/power
        # loss can corrupt the datadir — acceptable for a disposable dev DB, never
        # for production.
        innodb_flush_log_at_trx_commit = 0;
        innodb_doublewrite = 0;
        innodb_flush_method = "O_DIRECT_NO_FSYNC";

        # NVMe/SSD tuning — no benefit from neighbor-flushing on SSD, and the device
        # can sustain far more concurrent I/O than InnoDB's conservative defaults.
        innodb_flush_neighbors = 0;
        innodb_io_capacity = 4000;
        innodb_io_capacity_max = 8000;

        # Shopware ships hundreds of tables — keep them all cached to avoid
        # open/close churn during migrations and full-catalog operations.
        table_open_cache = 8000;
        table_definition_cache = 4000;

        # Large joins/GROUP BY and temp tables stay in memory instead of spilling to disk.
        tmp_table_size = "512M";
        max_heap_table_size = "512M";
        join_buffer_size = "256M";

        # Single local dev user → skip bookkeeping that only matters at scale/on shared hosts.
        performance_schema = 0;
        skip_name_resolve = 1;

        # No replication / point-in-time recovery needed locally; skipping the binary
        # log removes per-write I/O and speeds up large migrations & imports.
        skip-log-bin = 1;
      };
    };
  };

  services.redis.enable = lib.mkDefault true;
  services.redis.port = 6379;
  services.mailhog.enable = lib.mkDefault true;

  # Optional services — enable per project:
  # services.elasticsearch.enable = true;   # or OpenSearch, see SHOPWARE_ES_* env
  # services.rabbitmq.enable = true;
  # services.rabbitmq.managementPlugin.enable = true;

  # ─── Environment variables ──────────────────────────────────────────────────
  env.COMPOSER_HOME = "${toString ./.}/.composer";
  env.APP_URL = lib.mkDefault "http://${host}";
  env.CYPRESS_baseUrl = lib.mkDefault "http://${host}";
  env.DATABASE_URL = lib.mkDefault "mysql://root@localhost:3306/shopware";
  env.MAILER_DSN = lib.mkDefault "smtp://localhost:1025";
  env.SQL_SET_DEFAULT_SESSION_VARIABLES = lib.mkDefault "0";

  # ─── Installer tasks — nice step-by-step UX: `devenv tasks run shop:install` ───
  # `status` makes each step idempotent (skipped when already done). `after` gives
  # the ordering. shop:install needs the services running (`devenv up` in another
  # shell) because it talks to MySQL.
  tasks = {
    "shop:composer-install" = {
      description = "Install PHP dependencies (Shopware core + bundles via Symfony Flex)";
      exec = ''
        composer install --no-scripts --no-interaction
        composer symfony:recipes:install --yes --no-interaction
        chmod 755 bin/*
      '';
      status = "test -f bin/console";
    };

    "shop:install" = {
      description = "Install Shopware into the database (creates DB + admin user admin/shopware)";
      exec = "php bin/console system:install --create-database --basic-setup --force";
      after = [ "shop:composer-install" ];
      status = "test -f install.lock";
    };

    "shop:build-js" = {
      description = "Build Administration + Storefront assets (optional)";
      exec = "test -x bin/build-js.sh && ./bin/build-js.sh || echo 'bin/build-js.sh missing — run shop:composer-install first'";
      after = [ "shop:composer-install" ];
    };
  };

  # ─── Background workers ───────────────────────────────────────────────────────
  # These require an INSTALLED shop (bin/console must exist and the DB must be set
  # up). Uncomment after `composer install` + `bin/console system:install`, otherwise
  # they crash-loop on `devenv up` for a fresh, not-yet-installed template.
  #
  # processes = {
  #   queue-worker = {
  #     exec = "php -d memory_limit=512M bin/console messenger:consume --time-limit=300 async low_priority failed scheduler_shopware";
  #     restart = { on = "always"; max = null; };
  #     after = [
  #       "devenv:processes:mysql@ready"
  #       "devenv:processes:phpfpm-web@started"
  #       "devenv:processes:redis@started"
  #     ];
  #   };
  #   scheduled-task-runner = {
  #     exec = "php -d memory_limit=256M bin/console scheduled-task:run";
  #     restart = { on = "always"; max = null; };
  #     after = [
  #       "devenv:processes:mysql@ready"
  #       "devenv:processes:phpfpm-web@started"
  #     ];
  #   };
  # };
}
