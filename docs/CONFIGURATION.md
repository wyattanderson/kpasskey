# Application-owned Kerberos configuration

`xpc/Configuration.swift` defines the typed password configuration. The client
sends an immutable snapshot; the worker validates it again. Secrets, MIT profile
text, plugin paths, environment changes and arbitrary cache/file destinations
are not settings. Passkey, RP mapping and PKINIT trust belong to milestone 4.

## Settings schema

`--settings path.plist` accepts a partial plist that overlays application
defaults. Unknown top-level keys and invalid types/values fail closed. Managed
preference ingestion is deferred to the native settings application; the worker
consumes effective values only.

| Field | Default and supported policy |
| --- | --- |
| `schema` | `1`; other schemas rejected |
| `principal` | Required; username or `username@REALM`, no product default |
| `realm` | Empty; optional explicit realm, must agree with a qualified principal |
| `discoveryDomain` | Empty; optional DNS domain for an unqualified username |
| `dnsDiscovery` | `true`; DNS realm and KDC discovery |
| `kdcs` | Empty; up to eight dictionaries containing `host` and `port`; explicit endpoints require a realm |
| `transport` | `tcpFirst` or `udpFirst`, with MIT's native TCP/UDP fallback |
| `canonicalize` | `false`; opt in to KDC principal canonicalization/referrals |
| `forwardable` | `true`; `false` requests nonforwardable tickets |
| `lifetimeSeconds` | 36,000; range 300–604,800 |
| `renewableLifetimeSeconds` | 604,800; range 0–2,592,000; zero disables the explicit renewable request |
| `makeDefault` | `true`; switch to the newly populated shared API cache |
| `timeoutMilliseconds` | 30,000; range 200–30,000, covering interaction and authentication |
| `networkTimeoutSeconds` | 5; range 1–30, per MIT KDC exchange |

Names are bounded to 256 UTF-8 bytes and reject control characters. Password
mode accepts a single username component: escaped names, service components
and multiple `@` separators are rejected. Endpoints accept DNS names or IPv4
literals and ports 1–65,535. IPv6 literals and HTTPS KDC proxies are not exposed
in this schema; DNS may return IPv6 addresses. Archives are bounded to 8 KiB.
The KDC controls actual lifetimes and flags; metadata reports its reply.

Example settings:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>principal</key><string>user</string>
  <key>discoveryDomain</key><string>example.org</string>
  <key>forwardable</key><false/>
</dict></plist>
```

## Discovery and name policy

A qualified principal takes precedence; otherwise an explicit realm is used.
With neither, MIT queries `_kerberos` TXT records for `discoveryDomain` and its
parents. Without a domain, MIT uses the local hostname and resolver search
domain. Missing TXT records fail with a configuration error; the heuristic
uppercase-domain hostrealm module is disabled.

Without explicit endpoints, MIT uses native URI/SRV discovery, including
`_kerberos._tcp.REALM` and `_kerberos._udp.REALM`, priorities, weights and
failover. Explicit endpoints disable both URI and SRV discovery for the
operation. Disabling DNS requires an explicit realm and endpoint list;
hostname-to-address resolution still uses the operating system resolver.
DNS supplies discovery information, not KDC authentication; normal Kerberos
reply verification remains enabled.

Reverse DNS and hostname canonicalization are disabled. Principal
canonicalization is separately configurable and defaults off. No cross-realm
mapping or lab-domain assumption is installed on the machine.

## In-memory MIT profile

`makeProfile` calls `profile_init(nil, ...)` to create an empty **non-null**
profile, then `profile_add_relation`. The selected upstream implementation
creates a memory-only tree when the first relation is added. Ownership freezes
it after construction. `krb5_init_context_profile` copies it with
`KRB5_INIT_CONTEXT_SECURE`; the original is then abandoned. No profile file is
opened or written. Every operation creates and frees its own context.

This replaces the proposed custom `profile_init_vtable` backend: MIT already
provides lookup, copy and iteration for its native memory tree. Tests exercise
missing relations, repeated values, section iteration and copied-profile
lifetime against the bundled library. Implementation details were checked in
the pinned upstream `prof_init.c`, `prof_set.c` and `prof_file.c`. No C or
Objective-C implementation shim is necessary.

Forwardability, proxiability (off), canonicalization, ticket lifetime,
renewable lifetime and password-change prompting (off) also use explicit
initial-credential options. Only the built-in encrypted timestamp client
preauthentication module is enabled. Neither passkey nor stock PKINIT is
loaded. Unexpected prompter calls are rejected; password changes and OTP
prompts are not silently answered.

## Environment and plugin audit

The secure-context flag does not sanitize every backend:

| Upstream path | Application policy |
| --- | --- |
| `init_os_ctx.c`: configuration files and `KRB5_CONFIG` | Non-null application profile and secure context; no file initialization |
| `trace.c`: `KRB5_TRACE` | Secure initialization skips environment tracing; no trace callback |
| `ccdefname.c`: `KRB5CCNAME` | Ignores the secure flag; set an explicit per-context MEMORY default and use explicit cache handles |
| `cc_memory.c` | Operation-owned MEMORY cache, no file/environment lookup |
| `cc_api_macos.c` | Unique API cache via upstream CCAPI/GSSCred; no user-supplied residual or default-cache resolution |
| FILE, DIR, KCM, ccselect, keytab backends | Not used in this path; no collection/default-keytab lookup |
| New plugin interface | Profile sets module allowlists and a root-owned nonexistent plugin base |
| Legacy KDC locator | Build patch empties its directory list; otherwise it scans host directories independently of the profile, with no public disabling API |
| OpenSSL/resolver overrides | Startup removes `OPENSSL_CONF`, `OPENSSL_CONF_INCLUDE`, `OPENSSL_MODULES`, `OPENSSL_ENGINES`, `RANDFILE`, `LOCALDOMAIN`, `RES_OPTIONS`, `HOSTALIASES` |

Worker startup also removes Kerberos configuration, cache, trace and keytab
variables once, before native work. No per-request global environment mutation
occurs. OpenSSL's compiled defaults/module paths remain constrained by the
build. The native resolver and user's login-session credential daemon remain
intentional dependencies. The legacy cache API/private GSSCred protocol
compatibility risks are described in BUILD.md.
The worker explicitly joins the host's audit session with `JoinExistingSession`;
otherwise an XPC service has its own session and its caches are not shared with
the user's terminal or other system consumers.

## Publication, cancellation and secrets

The console reads `/dev/tty` with echo disabled, bounded to 4 KiB, and sends
password bytes in a separate XPC field. Ctrl-C, EOF, empty input and interaction
expiry cancel. No password is accepted in arguments, environment or plists.
Owned terminal/C buffers are cleared; Foundation/XPC copies cannot promise
universal erasure. Logging includes only categories, numeric MIT errors and
ticket metadata.

Synchronous authentication runs off the main actor and stages credentials in a
unique MEMORY cache. A short synchronized gate arbitrates cancellation against
publication. If cancellation wins, publication cannot begin. XPC acknowledges
cancellation and sends one terminal result immediately; native work still
draining holds the global busy slot. After a 750 ms grace period, a blocked
embedded worker exits, releasing its memory-only resources. Reconnect after
that exit; there is no implicit retry. This bounds abandoned resolver/library
calls without changing global resolver settings.

Once the gate commits, cancellation cannot undo publication. A fresh API cache
is created, initialized with the returned principal and populated from staging.
Only this new cache is destroyed on publication failure; unrelated caches are
never initialized or destroyed. `makeDefault` switches only after storage.
Disabling it preserves an existing default (the OS may make its first cache
the default). Repeated successes create distinct caches; old-ticket deletion
is outside this milestone.

Success metadata is emitted only after publication/default-switch success:
principal, realm, API cache reference, expiry, renewal time, actual forwardable
flag and password mode. Authentication and publication failures are distinct.
The client rejects password success without metadata. Staging credentials and
native allocations are freed on every ordinary exit.

A worker/reply loss during commit can leave the outcome unknown to the client.
The native shared-cache RPC has no public cancellation/timeout API; the client
watchdog reports worker loss if it hangs, without claiming success or destroying
another cache. This differs from pre-publication cancellation.

## Validation

`bazel test --config=development //:milestone3` covers configuration, secret
archives, native profile/options, cancellation, unavailable KDCs, sequential
snapshots and password XPC after relocation. Synthetic tests run with conflicting
Kerberos environment values and do not modify shared caches. Live acceptance is
tracked separately in PLAN.md.

The password-free DNS test is opt-in: run `//xpc:kerberos_tests` with
`--sandbox_default_allow_network=true`, `--test_env=KPASSKEY_TEST_DNS_DOMAIN=example.org`
and `--test_env=KPASSKEY_TEST_DNS_REALM=EXAMPLE.ORG`. Ordinary tests skip this
live lookup and keep Bazel's default network sandbox.

Build/extract the harness as described in BUILD.md, then run
`KPasskeyHarness --password user@REALM` or `--settings path.plist` in a terminal.
Inspect the returned cache with `/usr/bin/klist -c API:returned-name` and test a
real system Kerberos consumer against a service in that realm. Verify both
forwardability settings, wrong password using a safe test account, cancellation,
coexistence with an existing cache, and publication failure after successful
authentication. Do not exhaust account lockout attempts. Clean up only the
cache names returned by test operations, never the whole collection.
