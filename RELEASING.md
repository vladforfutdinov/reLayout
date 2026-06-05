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

### Homebrew tap (optional, for `brew install --cask`)

1. Create a public repo **`homebrew-relayout`** under your account (an empty repo
   is fine — CI populates `Casks/relayout.rb` on the first release).
2. Create a fine-grained Personal Access Token with **Contents: read and write**
   on that repo, and add it here as the secret **`TAP_GITHUB_TOKEN`**.

On each release, CI renders the cask from `packaging/homebrew/relayout.rb.tmpl`
(filling in the version and the DMG's sha256) and pushes it to the tap. Users then:

```sh
brew install --cask vladforfutdinov/relayout/relayout
```

If `TAP_GITHUB_TOKEN` is unset the release still succeeds — the tap bump is skipped.

## Cutting a release

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

CI then signs, notarizes, staples, and attaches the DMG/zip to the Release.
Watch it: `gh run watch` · verify: `gh release view vX.Y.Z`.

## Local signed build (optional)

```sh
SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./build.sh
ditto -c -k --keepParent ReLayout.app notarize.zip
AC_API_KEY_PATH=AuthKey.p8 AC_API_KEY_ID=… AC_API_ISSUER_ID=… ./notarize.sh notarize.zip ReLayout.app
./make-dmg.sh
```

Without `SIGN_IDENTITY`, `build.sh` falls back to the local self-signed identity
(`./make-cert.sh`) or ad-hoc — fine for development, not for distribution.
