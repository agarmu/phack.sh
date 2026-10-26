# Shared test assertions and command execution.

export def assert-equal [actual, expected, message: string] {
    if $actual != $expected { error make {msg: $message} }
}

export def assert-contains [actual: string, expected: string, message: string] {
    if not ($actual | str contains $expected) { error make {msg: $message} }
}

export def assert-exists [path: path, message: string] {
    if not ($path | path exists) { error make {msg: $message} }
}

export def assert-absent [path: path, message: string] {
    if ($path | path exists) { error make {msg: $message} }
}

export def require [condition: bool, message: string] {
    if not $condition { error make {msg: $message} }
}

export def run_checked [program: string, ...args: string] {
    let result = do -i { ^$program ...$args } | complete
    require ($result.exit_code == 0) $'($program) failed: ($result.stderr)'
    $result
}
