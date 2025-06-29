#!/usr/bin/env bash

# This script runs all integration tests.

set -e -o pipefail

cd http1-basic
dub build --single http1-test.d
./http1-test

cd ..
