use _lib.nu ROOT
use _test-lib.nu [require run_checked]

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

export def main [] {
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
        let miniflux_file = $base | path join 'miniflux-postgres-password'
        $main_password | save --force $miniflux_file
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
                '-f'
                ($ROOT | path join 'postgres/cms.sql')
                '-f'
                ($ROOT | path join 'postgres/miniflux.sql')
            ) | ignore
        }
        do $initialize

        for pair in [
            ['cms', $main_password]
            ['cms_demo', $demo_password]
            ['miniflux', $main_password]
        ] {
            let role = $pair.0
            let password = $pair.1
            let own = (connect $psql $base $port $role $role $password)
            require ($own.exit_code == 0) $'($role) could not connect to its database: ($own.stderr)'
            for other in ([cms cms_demo miniflux] | where {|name| $name != $role }) {
                let denied = (connect $psql $base $port $role $other $password)
                require ($denied.exit_code != 0) $'($role) unexpectedly connected to ($other)'
                require ($denied.stderr | str contains 'permission denied') $'connection to ($other) failed for an unexpected reason: ($denied.stderr)'
            }
        }
        require (
            (
                (sql
                    $psql
                    $base
                    $port
                    "SELECT count(*) FROM pg_roles WHERE rolname IN ('cms', 'cms_demo', 'miniflux') AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole"
                )
            ) == '3'
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

        sql $psql $base $port "CREATE TABLE keep_me (value text); INSERT INTO keep_me VALUES ('preserved')" --database 'miniflux' | ignore
        'different-password' | save --force $miniflux_file
        do $initialize
        require (
            ((connect
                $psql
                $base
                $port
                'miniflux'
                'miniflux'
                $main_password
            )).exit_code == 0
        ) 'reinitialization rotated the Miniflux password'
        require (
            (
                sql $psql $base $port 'SELECT value FROM keep_me' --database 'miniflux'
            ) == 'preserved'
        ) 'reinitialization lost Miniflux data'

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
