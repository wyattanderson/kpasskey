#!/bin/bash
set -euo pipefail
cd "${TEST_SRCDIR}/${TEST_WORKSPACE}"
exec tests/dependency_probe "$1/lib/krb5/plugins/preauth/pkinit.so"
