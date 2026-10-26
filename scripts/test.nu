#!/usr/bin/env nu

use test-installer.nu
use test-postgres.nu

def main [] {
    test-installer
    test-postgres
}
