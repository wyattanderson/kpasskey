# How KPasskey works

KPasskey bundles its own MIT Kerberos client and passkey plugin, but the tickets it obtains end up in the same credential cache that native macOS applications use. There is no SSSD daemon to install, and it doesn't replace the system Kerberos libraries or change the machine's Kerberos configuration.

## From security key to ticket

The app handles the UI, while an embedded XPC worker handles authentication. The worker uses MIT Kerberos to talk to the KDC and `libfido2` to talk to your USB security key. Our plugin implements the passkey preauthentication protocol that FreeIPA expects; the underlying libraries handle Kerberos and FIDO2.

A passkey sign-in has three parts:

1. The worker authenticates the KDC using PKINIT and the realm's CA certificate, obtaining an anonymous ticket. This establishes FAST armor: a protected Kerberos exchange in which the KDC can send the passkey challenge.
2. The KDC supplies the challenge, allowed credentials, relying party domain, and user verification requirement. The worker asks your selected key for an assertion, prompting for a PIN or onboard verification as needed, and returns it to the KDC for verification.
3. Once authentication succeeds, the worker copies the TGT from a temporary, in-memory cache into a new macOS `API:` cache. Native Kerberos clients can then use it without knowing anything about KPasskey or the security key.

This requires a KDC that supports both passkey authentication and anonymous PKINIT. You'll also need a key already enrolled for your account; KPasskey doesn't enroll credentials or manage security key PINs.

The CA certificate must come from your administrator through a trusted channel. KPasskey expects the FreeIPA subject convention, where the certificate's Organization (`O`) exactly matches the realm, including case. That check helps catch a certificate selected for the wrong realm, but it doesn't make an untrusted certificate trustworthy. The relying party domain comes from the authenticated KDC, so there is no separate domain to configure in KPasskey.

## Keeping authentication contained

Both the app and worker are sandboxed. The worker has network and USB access; the app can read files you explicitly select. Neither needs root privileges, and there is no launch agent or system-wide helper. Release builds check the code signing identity at both ends of the XPC connection, requiring the expected application identifiers and the same Apple developer team.

The worker constructs its own Kerberos configuration for each sign-in and loads only the bundled authentication plugins it needs. System Kerberos configuration and environment overrides don't control the exchange. DNS can help find a KDC, but the CA certificate establishes trust in it.

Passkey sign-in requires FAST and won't fall back to password authentication. Password sign-in is a separate, explicit mode. A failed PIN or verification attempt ends the operation instead of automatically retrying. Passwords and PINs are never saved or logged. They do pass through the app and worker in memory, and we can't promise that every copy made by macOS is erased immediately.

Authentication leaves existing tickets alone. Each successful sign-in creates a new cache; failure while storing a ticket cleans up only that new cache. Cancellation prevents publication until the worker starts committing the ticket. If the worker disappears during that final step, a ticket may have been stored even though the app couldn't confirm success; check the ticket list before trying again.

## Living alongside macOS

The worker shares the app's login session so its tickets remain available to other applications after authentication finishes. The menubar status reflects the shared cache, including tickets obtained outside KPasskey. Authentication-method labels come from local cache metadata; an unreported method doesn't mean the ticket is invalid, and these labels aren't proof of the authentication policy enforced by the KDC.

The less convenient part is that MIT's macOS cache backend relies in part on Apple's private credential-service interfaces. It works through the system credential service, but Apple doesn't promise that interface will stay compatible. Testing authentication and ticket use on supported macOS releases remains necessary.

The build keeps dependencies pinned in Bazel and packages the libraries the app uses. It doesn't depend on a Homebrew installation at runtime. Xcode and the macOS SDK are still build inputs, so this isn't a claim that any two Macs will produce byte-for-byte identical applications. See [Building and releasing](BUILD.md) for the commands.
