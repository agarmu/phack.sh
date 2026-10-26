# Prepare credentials without writing until all installation inputs validate.
use _lib.nu [read-setting validate-password]

export def prepare-password [
    source: path
    managed: path
    expected
    --explicit
] {
    let existing = if ($source | path exists) or $explicit { $source } else { $managed }
    if ($existing | path exists) or $explicit {
        let value = read-setting $existing
        validate-password $existing ($expected | default $value)
        return {path: $existing, value: $value, write: false}
    }
    let value = if $expected != null {
        if ($expected | describe) != 'string' or ($expected | is-empty) or ($expected =~ '[\r\n\x00]') {
            error make {msg: 'Database password must be nonempty with no line breaks'}
        }
        $expected
    } else {
        let result = ^openssl rand -hex 32 | complete
        if $result.exit_code != 0 {
            error make {msg: 'Cannot generate database password with openssl'}
        }
        $result.stdout | str trim
    }
    {path: $managed, value: $value, write: true}
}

export def internal-value [value, placeholder: string] {
    if $value == null { error make {msg: $"Missing database password setting: ($placeholder)"} }
    if $value == $"{{($placeholder)}}" { null } else { $value }
}

export def toml-string-content [value: string] {
    $value | to json --raw | str substring 1..-2
}
