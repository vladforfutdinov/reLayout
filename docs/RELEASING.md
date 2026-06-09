# Releasing reLayout

A release is a git tag `vX.Y.Z`. Pushing it runs `.github/workflows/build.yml`,
which builds, **signs with Developer ID + Hardened Runtime, notarizes, staples**,
and publishes a GitHub Release with `reLayout.dmg` + `reLayout.zip`.

`main`/PR builds skip signing and notarization (ad-hoc), so they need no secrets.

## One-time: repository secrets

Set these under **Settings → Secrets and variables → Actions**.

### Developer ID certificate

1. In Xcode (or developer.apple.com) create a **Developer ID Application**
   certificate; make sure its private key is in your login keychain.
2. Export it from Keychain Access as a `.p12` (set an export password).
3. Base64 it:
   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   ```
   - `DEVELOPER_ID_CERT_P12_BASE64` ← that base64
   - `DEVELOPER_ID_CERT_PASSWORD` ← the export password

### App Store Connect API key (for notarytool)

1. App Store Connect → **Users and Access → Integrations → App Store Connect API**
   → generate a key with the **Developer** role. Download the `.p8` (one-time).
2. Note the **Key ID** and the **Issuer ID** shown on that page.
3. Base64 the key:
   ```sh
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```
   - `AC_API_KEY_ID` ← the Key ID
   - `AC_API_ISSUER_ID` ← the Issuer ID (UUID)
   - `AC_API_KEY_P8_BASE64` ← that base64

### Homebrew tap (for `brew install --cask`)

Already wired: the public repo **`homebrew-relayout`** has a write **deploy key**,
whose private key is the secret **`TAP_DEPLOY_KEY`**. On each release, CI renders
the cask from `packaging/homebrew/relayout.rb.tmpl` (version + DMG sha256) and
pushes it to the tap over SSH. Users then:

```sh
brew install --cask vladforfutdinov/relayout/relayout
```

If `TAP_DEPLOY_KEY` is unset the release still succeeds — the tap bump is skipped.
To rotate: regenerate the key, replace the deploy key on the tap, update the secret.

### Sparkle auto-update (EdDSA + appcast)

Release builds embed [Sparkle](https://sparkle-project.org) and check
`SUFeedURL` (`https://relayout.forfutdinov.com/appcast.xml`).

1. Build once with Sparkle to fetch the tools, then generate the EdDSA keypair:
   ```sh
   WITH_SPARKLE=1 ./scripts/build.sh
   .sparkle/*/bin/generate_keys            # stores the private key in your keychain
   .sparkle/*/bin/generate_keys -p         # prints the PUBLIC key
   ```
   - Put the **public** key in `macos/Info.plist` → `SUPublicEDKey` (replace
     `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`).
   - Export the **private** key and add it as the secret **`SPARKLE_ED_PRIVATE_KEY`**:
     ```sh
     .sparkle/*/bin/generate_keys -x sparkle_private.key   # the file's contents = the secret
     ```
2. Enable **GitHub Pages** for the repo, serving the **`gh-pages`** branch (root).
   CI creates/updates `appcast.xml` there on each release. The same branch also
   hosts the **landing page** (`index.html` + `logo.png`) served at
   `https://relayout.forfutdinov.com/` (custom domain via the `CNAME` file +
   a DNS `CNAME` record `relayout` → `vladforfutdinov.github.io`); the appcast step
   only touches `appcast.xml`, so it never clobbers the site or the `CNAME`.

On release, CI signs the embedded `Sparkle.framework` with your Developer ID
(same Team ID as the app, so Hardened Runtime's library validation passes),
notarizes, generates the signed appcast from `reLayout.zip`, and publishes it to
`gh-pages`. If `SPARKLE_ED_PRIVATE_KEY` is unset the appcast step is skipped.

## Cutting a release

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

CI then signs, notarizes, staples, and attaches the DMG/zip to the Release.
Watch it: `gh run watch` · verify: `gh release view vX.Y.Z`.

## Local signed build (optional)

```sh
SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./scripts/build.sh
ditto -c -k --keepParent dist/ReLayout.app notarize.zip
AC_API_KEY_PATH=AuthKey.p8 AC_API_KEY_ID=… AC_API_ISSUER_ID=… ./scripts/notarize.sh notarize.zip dist/ReLayout.app
./scripts/make-dmg.sh
```

Without `SIGN_IDENTITY`, `build.sh` falls back to the local self-signed identity
(`./scripts/make-cert.sh`) or ad-hoc — fine for development, not for distribution.
