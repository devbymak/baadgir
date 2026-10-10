#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/module-cache
parvanak_cache_path="$(cd .build/module-cache && pwd -P)"
xcrun swiftc -target arm64-apple-macosx13.0 -module-cache-path "$parvanak_cache_path" -swift-version 5 sources/policy.swift tests/main.swift -o .build/policy-tests
.build/policy-tests
