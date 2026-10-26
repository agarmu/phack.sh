#!/usr/bin/env nu

use _lib.nu [
    ROOT
    source-path
    read-setting
    read-toml
    check-command
]
use _credentials.nu [prepare-password internal-value toml-string-content]

const UNIT_PLACEHOLDER = '@([A-Z_]+)@'

def install-unit [destination: path, content: string] {
    let parent = $destination | path dirname
    ^mkdir -p -m 700 $parent
    check-command $env.LAST_EXIT_CODE 'Cannot create Quadlet directory'
    let result = ^mktemp ($parent | path join '.install.XXXXXXXXXX') | complete
    check-command $result.exit_code 'Cannot create temporary Quadlet'
    let temporary = $result.stdout | str trim
    try {
        $content | save --force --raw $temporary
        ^chmod 600 $temporary
        check-command $env.LAST_EXIT_CODE 'Cannot set Quadlet permissions'
        ^mv -f $temporary $destination
        check-command $env.LAST_EXIT_CODE 'Cannot install Quadlet'
    } catch {|err|
        rm --force $temporary
        error make {msg: $err.msg}
    }
}

def check-static-services [user_config: path] {
    for name in [
        cms
        cms-web-build
        cms-postgres
        caddy
        miniflux
        podman-stack-pod
    ] {
        let unit = $user_config | path join systemd user $"($name).service"
        if ($unit | path exists) {
            error make {msg: $"Static ($name).service shadows Quadlet: ($unit)"}
        }
    }
}

def main [
    --api-config: path
    --api-secrets: path
    --web-config: path
    --postgres-password: path
    --demo-postgres-password: path
    --miniflux-config: path
    --miniflux-postgres-password: path
] {
    let api = source-path ($api_config | default ($ROOT | path join config cms-api config.toml))
    let secrets = source-path ($api_secrets | default ($ROOT | path join config cms-api secrets.toml))
    let web = source-path ($web_config | default ($ROOT | path join config cms-web config.toml))
    let postgres = source-path (
        $postgres_password
        | default ($ROOT | path join config cms-postgres postgres-password)
    )
    let demo = source-path (
        $demo_postgres_password
        | default ($ROOT | path join config cms-postgres demo-postgres-password)
    )
    let miniflux = source-path ($miniflux_config | default ($ROOT | path join config miniflux miniflux.conf))
    let miniflux_password = source-path (
        $miniflux_postgres_password | default ($ROOT | path join config miniflux postgres-password)
    )
    let root = source-path $ROOT
    let user_config = if ($env.XDG_CONFIG_HOME? | default '' | is-empty) {
        $env.HOME | path join .config
    } else { $env.XDG_CONFIG_HOME }

    read-toml $api | ignore
    read-toml $web | ignore
    let managed = source-path ($user_config | path join podman-stack credentials)
    let credentials = try {
        let parsed = open --raw $secrets | from toml
        $parsed
    } catch { null }
    if $credentials == null { error make {msg: $"Invalid TOML in ($secrets)"} }
    let main_password = prepare-password $postgres ($managed | path join postgres-password) (
        internal-value ($credentials.database?.password? | default null) 'main_database_password'
    ) --explicit=($postgres_password != null)
    let demo_password = prepare-password $demo ($managed | path join demo-postgres-password) (
        internal-value ($credentials.demo?.database?.password? | default null) 'demo_database_password'
    ) --explicit=($demo_postgres_password != null)
    let raw_miniflux = open --raw $miniflux
    let database_password = try {
        let url = $raw_miniflux | lines | parse --regex '^DATABASE_URL=(.*)$' | get capture0 | last
        if ($url | str contains '{{miniflux_database_password_urlencoded}}') { null } else {
            $url | url parse | get password | url decode
        }
    } catch {
        error make {msg: $"Invalid or missing DATABASE_URL in ($miniflux)"}
    }
    let feed_password = prepare-password $miniflux_password ($managed | path join miniflux-postgres-password) $database_password --explicit=($miniflux_postgres_password != null)
    let secret_replacements = {
        main_database_password: (toml-string-content $main_password.value)
        demo_database_password: (toml-string-content $demo_password.value)
    }
    read-toml $secrets --replacements $secret_replacements | ignore
    let rendered_secrets = read-setting $secrets --replacements $secret_replacements
    let rendered_miniflux = read-setting $miniflux --replacements {
        miniflux_database_password_urlencoded: ($feed_password.value | url encode --all)
    }
    let secrets_path = if $rendered_secrets == (open --raw $secrets) {
        $secrets
    } else {
        $managed | path join cms-secrets.toml
    }
    let miniflux_path = if $rendered_miniflux == $raw_miniflux {
        $miniflux
    } else {
        $managed | path join miniflux.conf
    }
    check-static-services $user_config
    for name in [
        config/caddy/Caddyfile
        config/miniflux/Caddyfile
        config/cms-web/Caddyfile
        config/cms-web/Containerfile
        config/cms-web/.containerignore
        postgres/init.sql
        postgres/cms.sql
        postgres/miniflux.sql
        postgres/healthcheck.sh
    ] {
        if not ($ROOT | path join $name | path exists) {
            error make {msg: $"Missing checkout file: ($name)"}
        }
    }

    let replacements = {
        REPO_ROOT: $root
        API_CONFIG: $api
        API_SECRETS: $secrets_path
        WEB_CONFIG_DIR: ($web | path dirname)
        WEB_CONFIG_FILE: ($web | path basename)
        POSTGRES_PASSWORD: $main_password.path
        DEMO_POSTGRES_PASSWORD: $demo_password.path
        MINIFLUX_CONFIG: $miniflux_path
        MINIFLUX_POSTGRES_PASSWORD: $feed_password.path
    }
    | items {|key, value| {key: $key, value: ($value | str replace --all '%' '%%')} }
    | transpose --header-row --as-record
    let units = glob ($ROOT | path join quadlets '*') | each {|source|
        let content = open --raw $source
        | str replace --all --regex $UNIT_PLACEHOLDER {|name| $replacements | get $name }
        {name: ($source | path basename), content: $content}
    }
    for credential in [$main_password $demo_password $feed_password] {
        if $credential.write { install-unit $credential.path $credential.value }
    }
    if $secrets_path != $secrets { install-unit $secrets_path $rendered_secrets }
    if $miniflux_path != $miniflux { install-unit $miniflux_path $rendered_miniflux }
    let sockets = $env.HOME | path join .local share podman-stack caddy sockets
    ^mkdir -p -m 750 $sockets
    check-command $env.LAST_EXIT_CODE 'Cannot create socket directory'
    let quadlets = $user_config | path join containers systemd
    for unit in $units {
        install-unit ($quadlets | path join $unit.name) $unit.content
    }
    print 'Quadlets installed. Run systemctl --user daemon-reload, then systemctl --user restart podman-stack-pod.service.'
}
