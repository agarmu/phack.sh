# Shared repository paths and configuration validation.

export const ROOT = path self | path dirname | path dirname
export const PLACEHOLDER = '\{\{\s*([^{}\r\n]+?)\s*\}\}'

export def source-path [value: path] {
    let expanded = $value | path expand --no-symlink
    if $expanded =~ '[:\r\n\x00"\\]' {
        error make {
            msg: 'Paths must not contain colons, quotes, backslashes, or line breaks'
        }
    }
    $expanded
}

export def read-setting [source: path] {
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

export def read-toml [source: path] {
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

export def validate-password [source: path, expected] {
    let value = read-setting $source
    if ($value | is-empty) or ($value =~ '[\r\n\x00]') {
        error make {msg: $"Password file must be nonempty with no line breaks: ($source)"}
    }
    if ($expected | describe) != 'string' or $value != $expected {
        error make {
            msg: $"Password file must match its application database password: ($source)"
        }
    }
}

export def check-command [exit_code: int, message: string] {
    if $exit_code != 0 { error make {msg: $message} }
}
