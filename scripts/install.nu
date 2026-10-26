#!/usr/bin/env nu

const ROOT = path self | path dirname | path dirname
const PLACEHOLDER = '\{\{\s*([^{}\r\n]+?)\s*\}\}'
const UNIT_PLACEHOLDER = '@([A-Z_]+)@'

def source-path [value: path] {
    let expanded = $value | path expand
    if $expanded =~ '[:\r\n\x00"\\]' {
        error make {
            msg: 'Paths must not contain colons, quotes, backslashes, or line breaks'
        }
    }
    $expanded
}

def read-setting [source: path] {
    if not ($source | path exists) {
        error make {msg: $"Configuration file does not exist: ($source)"}
    }
    let content = open --raw $source
    let missing = $content | parse --regex $PLACEHOLDER
    if not ($missing | is-empty) {
        let name = $missing.0.capture0 | str trim
        error make {
            msg: $"Unresolved placeholder: ($name) in ($source); supply a rendered file"
        }
    }
    $content
}

def read-toml [source: path] {
    let content = read-setting $source
    let parsed = try {
        let parsed = $content | from toml
        $parsed
    } catch {
        null
    }
    if $parsed == null {
        error make {msg: $"Invalid TOML in ($source)"}
    }
    $parsed
}

def validate-password [source: path, expected] {
    let value = read-setting $source
    if ($value | is-empty) or ($value =~ '[\r\n\x00]') {
        error make {msg: $"Password file must be nonempty with no line breaks: ($source)"}
    }
    if ($expected | describe) != 'string' or $value != $expected {
        error make {
            msg: $"Password file must match its CMS API database password: ($source)"
        }
    }
}

def check-command [exit_code: int, message: string] {
    if $exit_code != 0 { error make {msg: $message} }
}

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
    for name in [cms cms-web-build cms-postgres caddy podman-stack-pod] {
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
    let root = source-path $ROOT
    let user_config = if ($env.XDG_CONFIG_HOME? | default '' | is-empty) {
        $env.HOME | path join .config
    } else { $env.XDG_CONFIG_HOME }

    read-toml $api | ignore
    read-toml $web | ignore
    let credentials = read-toml $secrets
    validate-password $postgres ($credentials.database?.password? | default null)
    validate-password $demo ($credentials.demo?.database?.password? | default null)
    check-static-services $user_config
    for name in [
        config/caddy/Caddyfile
        config/cms-web/Caddyfile
        config/cms-web/Containerfile
        config/cms-web/.containerignore
        postgres/init.sql
        postgres/healthcheck.sh
    ] {
        if not ($ROOT | path join $name | path exists) {
            error make {msg: $"Missing checkout file: ($name)"}
        }
    }

    let replacements = {
        REPO_ROOT: $root
        API_CONFIG: $api
        API_SECRETS: $secrets
        WEB_CONFIG_DIR: ($web | path dirname)
        WEB_CONFIG_FILE: ($web | path basename)
        POSTGRES_PASSWORD: $postgres
        DEMO_POSTGRES_PASSWORD: $demo
    }
    | items {|key, value| {key: $key, value: ($value | str replace --all '%' '%%')} }
    | transpose --header-row --as-record
    let units = glob ($ROOT | path join quadlets '*') | each {|source|
        let content = open --raw $source
        | str replace --all --regex $UNIT_PLACEHOLDER {|name| $replacements | get $name }
        {name: ($source | path basename), content: $content}
    }
    let sockets = $env.HOME | path join .local share podman-stack caddy sockets
    ^mkdir -p -m 750 $sockets
    check-command $env.LAST_EXIT_CODE 'Cannot create socket directory'
    let quadlets = $user_config | path join containers systemd
    for unit in $units {
        install-unit ($quadlets | path join $unit.name) $unit.content
    }
    print 'Quadlets installed. Run systemctl --user daemon-reload, then systemctl --user restart podman-stack-pod.service.'
}
