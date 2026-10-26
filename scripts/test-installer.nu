use _lib.nu [ROOT PLACEHOLDER]
use _test-lib.nu [assert-equal assert-contains assert-exists assert-absent]

def setup-case [base: path] {
    let repo = $base | path join 'repo with spaces'
    mkdir $repo
    for name in [quadlets postgres config] { cp -r ($ROOT | path join $name) $repo }
    mkdir ($repo | path join scripts)
    for name in [install.nu _lib.nu _credentials.nu] {
        cp ($ROOT | path join scripts $name) ($repo | path join scripts $name)
    }
    for name in [
        cms-api/config.toml
        cms-api/secrets.toml
        cms-web/config.toml
        miniflux/miniflux.conf
    ] {
        let path = $repo | path join config $name
        open --raw $path
        | str replace --all --regex $PLACEHOLDER 'test-value'
        | save --force --raw $path
    }
    let postgres = $repo | path join config cms-postgres
    mkdir $postgres
    for name in [postgres-password demo-postgres-password] {
        'test-value' | save --raw ($postgres | path join $name)
    }
    'test-value' | save --raw ($repo | path join config miniflux postgres-password)
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
        postgres/cms.sql
        postgres/miniflux.sql
        config/miniflux/Caddyfile
        config/miniflux/miniflux.conf
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
        [miniflux/miniflux.conf, miniflux.conf]
        [miniflux/postgres-password, miniflux-password]
    ]
    for pair in $pairs { cp ($fixture.repo | path join config $pair.0) ($managed | path join $pair.1) }
    '{{not_configured}}' | save --force --raw ($fixture.repo | path join config cms-api config.toml)
    let result = (run-installer $fixture
        '--api-config' ($managed | path join api.toml)
        '--api-secrets' ($managed | path join api-secrets.toml)
        '--web-config' ($managed | path join frontend-public.toml)
        '--postgres-password' ($managed | path join main-password)
        '--demo-postgres-password' ($managed | path join demo-password)
        '--miniflux-config' ($managed | path join miniflux.conf)
        '--miniflux-postgres-password' ($managed | path join miniflux-password))
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
        ((run-installer $fixture '--demo-postgres-password' ($file | into string)).exit_code != 0)
        true
        'Missing explicitly supplied password file should fail'
    )
    assert-no-installation $fixture
}

def test-miniflux-configuration [base: path] {
    let fixture = setup-case $base
    let config = $fixture.repo | path join config miniflux miniflux.conf
    let password = $fixture.repo | path join config miniflux postgres-password
    let original = open --raw $config
    $original | str replace 'miniflux:test-value@' 'miniflux:test%21value@' | save --force --raw $config
    'test!value' | save --force --raw $password
    let result = run-installer $fixture
    assert-equal $result.exit_code 0 $result.stderr
}

def test-invalid-miniflux-configuration [base: path] {
    let fixture = setup-case $base
    let config = $fixture.repo | path join config miniflux miniflux.conf
    let original = open --raw $config
    for value in [
        (
            $original
            | str replace 'miniflux:test-value@' 'miniflux:wrong-password@'
        )
        ($original | str replace 'DATABASE_URL=' 'MISSING_DATABASE_URL=')
        (
            $original
            | str replace 'ADMIN_PASSWORD=test-value' 'ADMIN_PASSWORD={{missing}}'
        )
        'DATABASE_URL=http://[sensitive-example-value'
    ] {
        $value | save --force --raw $config
        let result = run-installer $fixture
        (assert-equal
            ($result.exit_code != 0)
            true
            'Invalid Miniflux configuration should fail'
        )
        (assert-equal
            ($result.stderr | str contains 'sensitive-example-value')
            false
            'Do not expose configuration in errors'
        )
        assert-no-installation $fixture
    }
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

def file-mode [path: path] {
    let result = do -i { ^stat -c '%a' $path } | complete
    if $result.exit_code == 0 { $result.stdout } else { ^stat -f '%Lp' $path }
}

def test-generated-passwords [base: path] {
    let fixture = setup-case $base
    let secrets = $fixture.repo | path join config cms-api secrets.toml
    let miniflux = $fixture.repo | path join config miniflux miniflux.conf
    let original = open --raw $secrets | from toml
    $original
    | upsert database.password '{{main_database_password}}'
    | upsert demo.database.password '{{demo_database_password}}'
    | to toml
    | save --force $secrets
    open --raw $miniflux
    | str replace 'miniflux:test-value@' 'miniflux:{{miniflux_database_password_urlencoded}}@'
    | save --force $miniflux
    for file in [
        cms-postgres/postgres-password
        cms-postgres/demo-postgres-password
        miniflux/postgres-password
    ] {
        rm ($fixture.repo | path join config $file)
    }
    let inputs = [$secrets $miniflux] | each {|file| open --raw $file }
    let result = run-installer $fixture
    assert-equal $result.exit_code 0 $result.stderr
    let managed = $fixture.user_config | path join podman-stack credentials
    for file in [
        postgres-password
        demo-postgres-password
        miniflux-postgres-password
        cms-secrets.toml
        miniflux.conf
    ] {
        let path = $managed | path join $file
        let mode = file-mode $path
        assert-equal ($mode | str trim) '600' 'Private files must be mode 600'
    }
    let mode = file-mode $managed
    assert-equal ($mode | str trim) '700' 'Credential directory must be mode 700'
    let names = [postgres-password demo-postgres-password miniflux-postgres-password]
    let passwords = $names | each {|name| open --raw ($managed | path join $name) }
    assert-equal ($passwords | uniq | length) 3 'Generate independent passwords'
    for value in $passwords {
        assert-equal ($value =~ '^[0-9a-f]{64}$') true 'Generate 256-bit passwords'
        assert-equal ($result.stdout | str contains $value) false 'Do not print passwords'
    }
    let rendered = open --raw ($managed | path join cms-secrets.toml) | from toml
    assert-equal $rendered.database.password $passwords.0 'CMS password must match PostgreSQL'
    assert-equal $rendered.demo.database.password $passwords.1 'Demo password must match PostgreSQL'
    let feed = open --raw ($managed | path join miniflux.conf)
    assert-contains $feed $'miniflux:($passwords.2)@' 'Miniflux password must match PostgreSQL'
    let units = $fixture.user_config | path join containers systemd
    assert-contains (open --raw ($units | path join cms.container)) $'Volume=($managed)/cms-secrets.toml:' 'Mount rendered CMS secrets'
    assert-contains (open --raw ($units | path join miniflux.container)) $'Volume=($managed)/miniflux.conf:' 'Mount rendered Miniflux config'
    assert-equal (run-installer $fixture).exit_code 0 'Reinstallation should succeed'
    assert-equal ($names | each {|name| open --raw ($managed | path join $name) }) $passwords 'Reinstall must preserve passwords'
    assert-equal ([$secrets $miniflux] | each {|file| open --raw $file }) $inputs 'Do not modify templates'
}

def test-password-template-escaping [base: path] {
    let fixture = setup-case $base
    let secrets = $fixture.repo | path join config cms-api secrets.toml
    let value = 'quote"backslash\percent%plus+λ'
    open --raw $secrets
    | from toml
    | upsert database.password '{{main_database_password}}'
    | to toml
    | save --force $secrets
    $value | save --force --raw ($fixture.repo | path join config cms-postgres postgres-password)
    let result = run-installer $fixture
    assert-equal $result.exit_code 0 $result.stderr
    let rendered = open --raw ($fixture.user_config | path join podman-stack credentials cms-secrets.toml) | from toml
    assert-equal $rendered.database.password $value 'Escape existing passwords correctly in TOML'
}

def test-adopt-passwords [base: path] {
    let fixture = setup-case $base
    for file in [
        cms-postgres/postgres-password
        cms-postgres/demo-postgres-password
        miniflux/postgres-password
    ] {
        rm ($fixture.repo | path join config $file)
    }
    let result = run-installer $fixture
    assert-equal $result.exit_code 0 $result.stderr
    let managed = $fixture.user_config | path join podman-stack credentials
    for name in [postgres-password demo-postgres-password miniflux-postgres-password] {
        assert-equal (open --raw ($managed | path join $name)) 'test-value' 'Adopt existing application passwords'
    }
}

export def main [] {
    let cases = [
        {|base| test-direct-checkout-paths $base }
        {|base| test-external-configuration-paths $base }
        {|base| test-invalid-toml $base 'cms-api' }
        {|base| test-invalid-toml $base 'cms-web' }
        {|base| test-unresolved-placeholder $base }
        {|base| test-invalid-password $base }
        {|base| test-shadowing-static-unit $base }
        {|base| test-secret-parse-error-is-private $base }
        {|base| test-generated-passwords $base }
        {|base| test-adopt-passwords $base }
        {|base| test-password-template-escaping $base }
        {|base| test-miniflux-configuration $base }
        {|base| test-invalid-miniflux-configuration $base }
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
