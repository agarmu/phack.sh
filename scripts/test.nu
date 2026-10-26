#!/usr/bin/env nu

const ROOT = path self | path dirname | path dirname

def assert-equal [actual, expected, message: string] {
    if $actual != $expected { error make {msg: $message} }
}

def assert-contains [actual: string, expected: string, message: string] {
    if not ($actual | str contains $expected) { error make {msg: $message} }
}

def assert-exists [path: path, message: string] {
    if not ($path | path exists) { error make {msg: $message} }
}

def assert-absent [path: path, message: string] {
    if ($path | path exists) { error make {msg: $message} }
}

def setup-case [base: path] {
    let repo = $base | path join 'repo with spaces'
    mkdir $repo
    for name in [quadlets postgres config] { cp -r ($ROOT | path join $name) $repo }
    mkdir ($repo | path join scripts)
    cp ($ROOT | path join scripts install.nu) ($repo | path join scripts install.nu)
    for name in [cms-api/config.toml cms-api/secrets.toml cms-web/config.toml] {
        let path = $repo | path join config $name
        open --raw $path
        | str replace --all --regex '\{\{\s*([^{}\r\n]+?)\s*\}\}' 'test-value'
        | save --force --raw $path
    }
    let postgres = $repo | path join config cms-postgres
    mkdir $postgres
    for name in [postgres-password demo-postgres-password] {
        'test-value' | save --raw ($postgres | path join $name)
    }
    let home = $base | path join home
    let bin = $base | path join bin
    mkdir $home $bin
    let podman = $bin | path join podman
    "#!/bin/sh\nprintf 'called' > \"$PODMAN_LOG\"\nexit 1\n" | save --raw $podman
    ^chmod 755 $podman
    {
        repo: $repo
        home: $home
        user_config: ($base | path join user-config)
        data: ($home | path join .local share podman-stack)
        log: ($base | path join podman.log)
        path: ([$bin] | append $env.PATH)
        nu: (which nu | get path.0)
    }
}

def run-installer [fixture: record, ...args: string] {
    with-env {
        HOME: $fixture.home
        XDG_CONFIG_HOME: $fixture.user_config
        PODMAN_LOG: $fixture.log
        PATH: $fixture.path
    } {
        do -i { ^($fixture.nu) --no-config-file ($fixture.repo | path join scripts install.nu) ...$args | complete }
    }
}

def assert-no-installation [fixture: record] {
    assert-absent $fixture.user_config 'Validation must happen before Quadlet installation'
    assert-absent $fixture.data 'Validation must happen before socket directory creation'
    assert-absent $fixture.log 'Installer must not call Podman'
}

def test-direct-checkout-paths [base: path] {
    let fixture = setup-case $base
    let sources = [
        config/cms-api/config.toml
        config/cms-api/secrets.toml
        config/cms-web/config.toml
        config/cms-web/Containerfile
        config/cms-web/.containerignore
        config/cms-web/Caddyfile
        config/caddy/Caddyfile
        postgres/init.sql
        postgres/healthcheck.sh
    ]
    let before = $sources | each {|name| open --raw ($fixture.repo | path join $name) | hash sha256 }
    let result = run-installer $fixture
    assert-equal $result.exit_code 0 $result.stderr
    let after = $sources | each {|name| open --raw ($fixture.repo | path join $name) | hash sha256 }
    (assert-equal
        $after
        $before
        'Installer must not change source configuration or support files'
    )
    assert-absent $fixture.log 'Installer must not call Podman'
    for name in [cms-api cms-web cms-postgres] {
        assert-absent ($fixture.data | path join $name) 'Installer must not copy service files into .local/share'
    }
    assert-exists ($fixture.data | path join caddy sockets) 'Writable socket directory should exist'

    let units = $fixture.user_config | path join containers systemd
    for source in (glob ($fixture.repo | path join quadlets '*')) {
        assert-exists ($units | path join ($source | path basename)) 'Every Quadlet should be installed'
    }
    for unit in (glob ($units | path join '*.container')) {
        let content = open --raw $unit
        (assert-equal
            ($content =~ '@[A-Z_]+@')
            false
            'Unit placeholders must be resolved'
        )
        for mount in ($content | lines | where {|line| $line | str starts-with 'Volume=' }) {
            let source = $mount | str replace 'Volume=' '' | str replace '%h' ($fixture.home | into string) | split row ':' | first
            if ($source | str ends-with '.volume') {
                assert-exists ($units | path join $source) 'Named-volume Quadlet should exist'
            } else {
                assert-exists $source 'Bind mounts must reference existing checkout, configuration, or socket paths'
            }
        }
    }
    let build = open --raw ($units | path join cms-web.build)
    (assert-contains
        $build
        $"File=($fixture.repo)/config/cms-web/Containerfile"
        'Containerfile must come directly from the checkout'
    )
    (assert-contains
        $build
        $'PodmanArgs="--build-context=cms-web-config=($fixture.repo)/config/cms-web"'
        'Frontend configuration path must support spaces'
    )
    (assert-contains
        $result.stdout
        'restart podman-stack-pod.service'
        'Print lifecycle command'
    )
    (assert-equal
        (run-installer $fixture).exit_code
        0
        'Installation should be repeatable'
    )
}

def test-external-configuration-paths [base: path] {
    let fixture = setup-case $base
    let managed = $base | path join 'managed config'
    mkdir $managed
    let pairs = [
        [cms-api/config.toml, api.toml]
        [cms-api/secrets.toml, api-secrets.toml]
        [cms-web/config.toml, frontend-public.toml]
        [cms-postgres/postgres-password, main-password]
        [cms-postgres/demo-postgres-password, demo-password]
    ]
    for pair in $pairs { cp ($fixture.repo | path join config $pair.0) ($managed | path join $pair.1) }
    '{{not_configured}}' | save --force --raw ($fixture.repo | path join config cms-api config.toml)
    let result = (run-installer $fixture
        '--api-config' ($managed | path join api.toml)
        '--api-secrets' ($managed | path join api-secrets.toml)
        '--web-config' ($managed | path join frontend-public.toml)
        '--postgres-password' ($managed | path join main-password)
        '--demo-postgres-password' ($managed | path join demo-password))
    assert-equal $result.exit_code 0 $result.stderr
    let units = $fixture.user_config | path join containers systemd
    let api = open --raw ($units | path join cms.container)
    (assert-contains
        $api
        $"Volume=($managed)/api.toml:/app/config.toml:ro,Z"
        'Mount externally managed API config directly'
    )
    (assert-contains
        $api
        $"Volume=($managed)/api-secrets.toml:/app/secrets.toml:ro,Z"
        'Mount externally managed secrets directly'
    )
    let postgres = open --raw ($units | path join cms-postgres.container)
    (assert-contains
        $postgres
        $"Volume=($managed)/main-password:/run/cms-postgres-password:ro,Z"
        'Mount externally managed password directly'
    )
    let build = open --raw ($units | path join cms-web.build)
    (assert-contains
        $build
        $'--build-context=cms-web-config=($managed)'
        'Use supplied frontend config directory'
    )
    (assert-contains
        $build
        'BuildArg="CMS_WEB_CONFIG_FILE=frontend-public.toml"'
        'Use supplied frontend config filename'
    )
    assert-absent ($fixture.data | path join cms-api) 'Do not copy externally managed configuration'
    assert-absent $fixture.log 'Installer must not call Podman'
}

def test-invalid-toml [base: path, service: string] {
    let fixture = setup-case $base
    'invalid = [' | save --force --raw ($fixture.repo | path join config $service config.toml)
    let result = run-installer $fixture
    assert-equal ($result.exit_code != 0) true 'Invalid TOML should fail'
    (assert-contains
        $result.stderr
        'Invalid TOML'
        'Report invalid TOML without printing configuration contents'
    )
    assert-no-installation $fixture
}

def test-unresolved-placeholder [base: path] {
    let fixture = setup-case $base
    cp ($ROOT | path join config cms-web config.toml) ($fixture.repo | path join config cms-web config.toml)
    let result = run-installer $fixture
    (assert-equal
        ($result.exit_code != 0)
        true
        'Unrendered configuration should fail'
    )
    (assert-contains
        $result.stderr
        'Unresolved placeholder'
        'Report missing rendered configuration'
    )
    assert-no-installation $fixture
}

def test-invalid-password [base: path] {
    let fixture = setup-case $base
    let file = $fixture.repo | path join config cms-postgres demo-postgres-password
    for value in ['wrong-password' "test-value\n"] {
        $value | save --force --raw $file
        let result = run-installer $fixture
        (assert-equal
            ($result.exit_code != 0)
            true
            'Mismatched or multiline passwords should fail'
        )
        assert-no-installation $fixture
    }
    rm $file
    (assert-equal
        ((run-installer $fixture).exit_code != 0)
        true
        'Missing password file should fail'
    )
    assert-no-installation $fixture
}

def test-shadowing-static-unit [base: path] {
    let fixture = setup-case $base
    let unit = $fixture.user_config | path join systemd user cms-web-build.service
    mkdir ($unit | path dirname)
    'legacy unit' | save --raw $unit
    let result = run-installer $fixture
    (assert-equal
        ($result.exit_code != 0)
        true
        'Shadowing static service should fail'
    )
    (assert-contains
        $result.stderr
        'shadows Quadlet'
        'Report static unit conflict'
    )
    assert-absent ($fixture.user_config | path join containers) 'Conflict must prevent Quadlet installation'
    assert-absent $fixture.data 'Conflict must prevent runtime directory creation'
}

def test-secret-parse-error-is-private [base: path] {
    let fixture = setup-case $base
    'sensitive-example-value = [' | save --force --raw ($fixture.repo | path join config cms-api secrets.toml)
    let result = run-installer $fixture
    (assert-equal
        ($result.exit_code != 0)
        true
        'Invalid secrets TOML should fail'
    )
    (assert-equal
        ($result.stderr | str contains 'sensitive-example-value')
        false
        'Parse errors must not print secret file contents'
    )
    assert-no-installation $fixture
}

def test-installer [] {
    let cases = [
        {|base| test-direct-checkout-paths $base }
        {|base| test-external-configuration-paths $base }
        {|base| test-invalid-toml $base 'cms-api' }
        {|base| test-invalid-toml $base 'cms-web' }
        {|base| test-unresolved-placeholder $base }
        {|base| test-invalid-password $base }
        {|base| test-shadowing-static-unit $base }
        {|base| test-secret-parse-error-is-private $base }
    ]
    for test in $cases {
        let base = ^mktemp -d | str trim | path expand
        try {
            do $test ($base | into string)
            print 'PASS installer test'
        } catch {|err|
            rm -rf $base
            error make {msg: $"FAIL installer test: ($err.msg)"}
        }
        rm -rf $base
    }
}

def require [condition: bool, message: string] {
    if not $condition { error make {msg: $message} }
}

def run_checked [program: string, ...args: string] {
    let result = do -i { ^$program ...$args } | complete
    require ($result.exit_code == 0) $'($program) failed: ($result.stderr)'
    $result
}

def sql [
    psql: string
    base: path
    port: string
    query: string
    --database(-d): string = 'postgres'
] {
    let result = (
        (run_checked
            $psql
            '-h'
            ($base | into string)
            '-p'
            $port
            '-U'
            'postgres'
            '-d'
            $database
            '-XAt'
            '-v'
            'ON_ERROR_STOP=1'
            '-c'
            $query
        )
    )
    $result.stdout | str trim
}

def connect [
    psql: string
    base: path
    port: string
    role: string
    database: string
    password: string
] {
    with-env { PGPASSWORD: $password } {
        do -i { ^$psql '-h' '127.0.0.1' '-p' $port '-U' $role '-d' $database '-XAtw' '-c' 'SELECT current_database()' } | complete
    }
}

def test-postgres [] {
    let postgres_bin = $env.POSTGRES_BIN? | default ''
    if $postgres_bin == '' {
        print 'SKIP: set POSTGRES_BIN to run real PostgreSQL initialization tests'
        return
    }

    let temp = run_checked 'mktemp' '-d' | get stdout | str trim
    let base = $temp | path expand
    let cluster = $base | path join 'cluster'
    let initdb = $postgres_bin | path join 'initdb'
    let pg_ctl = $postgres_bin | path join 'pg_ctl'
    let psql = $postgres_bin | path join 'psql'
    let main_password = "main'\\password-λ"
    let demo_password = "demo'\\password-λ"
    try {
        let main_file = $base | path join 'cms-postgres-password'
        let demo_file = $base | path join 'cms-demo-postgres-password'
        $main_password | save --force $main_file
        $demo_password | save --force $demo_file
        let port = port | into string

        (run_checked
            $initdb
            '-D'
            $cluster
            '-U'
            'postgres'
            '--auth-local=trust'
            '--auth-host=scram-sha-256'
            '--pwfile'
            $main_file
            '--no-locale'
            '--encoding=UTF8'
        ) | ignore
        (run_checked
            $pg_ctl
            '-D'
            $cluster
            '-l'
            ($base | path join 'server.log')
            '-o'
            $'-k ($base) -h 127.0.0.1 -p ($port)'
            '-w'
            'start'
        ) | ignore

        let initialize = {||
            (run_checked
                $psql
                '-h'
                ($base | into string)
                '-p'
                $port
                '-U'
                'postgres'
                '-d'
                'postgres'
                '-X'
                '-v'
                $'password_dir=($base)'
                '-f'
                ($ROOT | path join 'postgres/init.sql')
            ) | ignore
        }
        do $initialize

        for pair in [
            ['cms', $main_password]
            ['cms_demo', $demo_password]
        ] {
            let role = $pair.0
            let password = $pair.1
            let own = (connect $psql $base $port $role $role $password)
            require ($own.exit_code == 0) $'($role) could not connect to its database: ($own.stderr)'
            let other = if $role == 'cms' { 'cms_demo' } else { 'cms' }
            let denied = (connect $psql $base $port $role $other $password)
            require ($denied.exit_code != 0) $'($role) unexpectedly connected to ($other)'
            require ($denied.stderr | str contains 'permission denied') $'connection to ($other) failed for an unexpected reason: ($denied.stderr)'
        }
        require (
            (
                (sql
                    $psql
                    $base
                    $port
                    "SELECT count(*) FROM pg_roles WHERE rolname IN ('cms', 'cms_demo') AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole"
                )
            ) == '2'
        ) 'application roles have unexpected privileges'

        sql $psql $base $port "CREATE TABLE keep_me (value text); INSERT INTO keep_me VALUES ('preserved')" --database 'cms' | ignore
        sql $psql $base $port 'DROP DATABASE cms_demo' | ignore
        sql $psql $base $port 'DROP ROLE cms_demo' | ignore
        do $initialize
        do $initialize
        require (
            (sql $psql $base $port 'SELECT value FROM keep_me' --database 'cms') == 'preserved'
        ) 'existing main database data was not preserved'
        require (
            (connect $psql $base $port 'cms_demo' 'cms_demo' $demo_password).exit_code == 0
        ) 'demo role failed after provisioning reruns'
        require ((connect $psql $base $port 'cms' 'cms' $main_password).exit_code == 0) 'main role failed after provisioning reruns'

        'different-password' | save --force $demo_file
        do $initialize
        require (
            (connect $psql $base $port 'cms_demo' 'cms_demo' $demo_password).exit_code == 0
        ) 'reinitialization rotated the existing demo password'
        require (
            ((connect
                $psql
                $base
                $port
                'cms_demo'
                'cms_demo'
                'different-password'
            )).exit_code != 0
        ) 'reinitialization adopted the changed password file'
        $demo_password | save --force $demo_file

        let health_env = {
            PATH: ([$postgres_bin] | append $env.PATH)
            PGPORT: $port
            CMS_POSTGRES_PASSWORD_DIR: ($base | into string)
        }
        let health_script = $ROOT | path join 'postgres/healthcheck.sh'
        let healthy = (
            with-env $health_env { do -i { ^bash $health_script } | complete }
        )
        require ($healthy.exit_code == 0) $'health check failed with both passwords: ($healthy.stderr)'
        'wrong-demo-password' | save --force $demo_file
        let unhealthy = (
            with-env $health_env { do -i { ^bash $health_script } | complete }
        )
        require ($unhealthy.exit_code != 0) 'health check accepted an incorrect demo password'
        $demo_password | save --force $demo_file
        print 'PASS: PostgreSQL initialization tests'
    } catch {|err|
        try {
            (run_checked
                $pg_ctl
                '-D'
                $cluster
                '-m'
                'immediate'
                '-w'
                'stop'
            ) | ignore
        }
        try { rm -rf $base }
        error make {msg: $err.msg}
    }

    try {
        run_checked $pg_ctl '-D' $cluster '-m' 'immediate' '-w' 'stop' | ignore
    }
    rm -rf $base
}

def main [] {
    test-installer
    test-postgres
}
