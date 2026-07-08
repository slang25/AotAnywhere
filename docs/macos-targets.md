# macOS targets

How AotAnywhere cross-compiles to `osx-x64` / `osx-arm64` from Windows and
Linux hosts, and how to sign and notarize the result for distribution.

## Cross-compilation with Apple linker stubs

No Apple SDK is available on Windows and Linux, so the package ships a minimal
set of self-generated Apple linker stubs (`.tbd` files, under
`build/apple-sysroot` in the package) covering exactly the symbols that .NET's
runtime packs reference in CoreFoundation, Foundation, Security, GSS, Network,
CryptoKit, the Swift runtime libraries, libobjc, libicucore and libz. This
means the base class library works as it does in a native macOS build,
including cryptography (CryptoKit/Security), HTTPS, and ICU globalization. Stubs
only matter at link time; at run time the real system libraries on the target
Mac are used.

Things to know:

- The stub symbol lists are generated from the .NET 8, 9, 10, and 11-preview
  runtime packs (`eng/generate-apple-sysroot.cs`). If a future .NET version
  references new Apple symbols, the link fails with an unresolved symbol until
  the stubs are regenerated.
- Symbols are not stripped for macOS targets (`StripSymbols` defaults to
  `false` there): Apple's `strip`/`dsymutil` are unavailable on other hosts and
  reject zig-linked binaries anyway.
- zig gives osx-arm64 binaries an ad-hoc code signature (Apple Silicon refuses
  to run entirely unsigned code); osx-x64 binaries are left unsigned. Either way
  that only covers running locally — for distribution you should sign (and if
  needed notarize) the result, which works from any host, no Mac required; see
  [Signing and notarizing](#signing-and-notarizing) below.
- To link against a real Apple SDK instead of the bundled stubs, set the
  `AotAnywhereAppleSysroot` MSBuild property (or the
  `AOTANYWHERE_APPLE_SYSROOT` environment variable) to the SDK root.

## Signing and notarizing

Out of the box the binaries only run locally: zig ad-hoc signs osx-arm64 output
(Apple Silicon requires at least that much) and leaves osx-x64 output unsigned.
That is not enough to distribute: anything downloaded with a browser gets
quarantined, and Gatekeeper only clears it when the binary is signed with a
Developer ID certificate and notarized by Apple. Both steps can be done from any
host — no Mac required.

### Signing during publish

Export your "Developer ID Application" certificate and private key as a `.p12`
file, put its password in a file, and pass both to publish:

```sh
dotnet publish -r osx-arm64 \
  /p:AotAnywhereSignP12File=certificate.p12 \
  /p:AotAnywhereSignP12PasswordFile=certificate.password.txt
```

The freshly linked binary is re-signed in place with the hardened-runtime flag
and a secure timestamp, so it is ready for notarization. This uses
[rcodesign](https://github.com/indygreg/apple-platform-rs) and works on Windows,
Linux and macOS hosts alike — install it from the GitHub releases (or `cargo
install apple-codesign`), or point `AotAnywhereRCodesignPath` at the executable
if it is not on `PATH`.

On a macOS host you can use Apple's `codesign` with a keychain identity instead:

```sh
dotnet publish -r osx-arm64 "/p:AotAnywhereCodesignIdentity=Developer ID Application: Jane Doe (TEAMID)"
```

To embed entitlements with either flavor, set
`/p:AotAnywhereEntitlements=path/to/entitlements.plist`.

Things to know:

- The password lives in a file rather than an MSBuild property so it does not
  end up in build logs or binlogs. In CI, store the `.p12` (base64-encoded) and
  its password as secrets and write them to files before publishing.
- If you create the `.p12` with OpenSSL 3+, pass `-legacy` (`openssl pkcs12
  -export -legacy ...`). rcodesign cannot read OpenSSL 3's default PFX
  encryption and fails with "incorrect password given when decrypting PFX data".
  Exports from Keychain Access work as-is.
- Signing happens right after the native link. On an incremental publish where
  the binary is up to date, the link is skipped and the existing binary is
  re-signed with the current properties — but if you *remove* the signing
  properties, the previous signature stays until something triggers a relink.
  Publish clean (or `dotnet clean`) when changing signing configuration.

### Notarizing

Notarization is a submission to Apple's notary service and needs an
[App Store Connect API key](https://gregoryszorc.com/docs/apple-codesign/stable/apple_codesign_app_store_connect.html).
Encode the key once:

```sh
rcodesign encode-app-store-connect-api-key -o api-key.json <issuer-id> <key-id> AuthKey_<key-id>.p8
```

Then either let the publish do everything — sign, zip, submit and wait for
Apple's verdict:

```sh
dotnet publish -r osx-arm64 \
  /p:AotAnywhereSignP12File=certificate.p12 \
  /p:AotAnywhereSignP12PasswordFile=certificate.password.txt \
  /p:AotAnywhereNotarize=true \
  /p:AotAnywhereNotaryApiKeyFile=api-key.json
```

or run the submission yourself after a signed publish:

```sh
zip hello.zip Hello
rcodesign notary-submit --api-key-file api-key.json --wait hello.zip
```

`AotAnywhereNotarize` requires Developer ID signing in the same publish (Apple
rejects ad-hoc submissions) and rcodesign, even when the signing itself was done
with `AotAnywhereCodesignIdentity`. Submission typically takes a minute or two;
the publish fails if Apple rejects the binary.

A bare executable cannot be stapled (stapling only works for bundles, disk
images and installer packages), so just distribute the notarized binary —
Gatekeeper fetches the notarization ticket online the first time it runs. If you
ship a `.dmg` or `.pkg` instead, notarize that artifact and `rcodesign staple`
it.

Note that only browser downloads get the quarantine attribute; binaries fetched
by `curl`, CI tooling or package managers typically run without any of this.
