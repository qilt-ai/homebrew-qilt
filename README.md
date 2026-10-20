# Qilt tap

The Homebrew tap for Qilt: `brew tap qilt-ai/qilt`, then `brew install qilt-ai/qilt/qilt`. Private during phase 0; each tester is granted read access by the tap's owner, and the install authenticates with the tester's own GitHub credential.

The formula is contributed by pull request and merged by the tap's owner only; the binary tarball it installs lives in the asset repository and is pinned by its hash in the formula. This README is the repository's initial commit (2026-10-20), placed by the Chief of Staff so the first formula can arrive as a reviewed pull request rather than as the repository's first content.

## Candidate preparation

This checkout prepares a formula for the compiled macOS arm64 release. No candidate formula is present until the release's measured version, two asset digests and macOS floor are supplied. The test data are synthetic and are never release pins.

Generate the single-file formula from the release record:

```sh
ruby scripts/render_formula.rb CANDIDATE.json Formula/qilt.rb
```

`CANDIDATE.json` has exactly `version`, `tarball_sha256`, `manifest_sha256` and `macos_minimum`. The digests come from the release's SHA256SUMS; the floor comes from that candidate's native manifest. Generation embeds the tested helpers so Homebrew can later read the formula from its installed `.brew` directory.

The downloader reads the installer's own `HOMEBREW_QILT_TOKEN` at fetch time. That account needs its own read grant to the private release repository. It uses the GitHub release API, verifies the formula's pinned checksum, never forwards authorization on a redirect, and emits fixed errors without response bodies or signed URLs. No publishing credential is used for a tester's download.

The formula retains the delivered manifest and the install record beside the versioned payload, outside the tree being verified. The accepted layout is:

```text
K/bin/qilt -> ../libexec/qilt/V/qilt
K/libexec/qilt/V/
K/libexec/qilt/qilt-V-macos-arm64.native-manifest.json
K/libexec/qilt/V.install.json
```

The record fields are `version`, `tarball_sha256`, `manifest_sha256` and `manifest_path`; the last is a basename relative to the record's directory. Pre-install checks preserve archive membership, bytes, modes and the declared symlink. N-2's native verifier is the post-install gate after Homebrew's relocation.

The qualified installation is **`brew install … && <K>/bin/qilt doctor --installation`**, where K is the resolved keg prefix. The native verifier runs before a store or service exists; its command contract is pinned, and native qualification is still pending. Homebrew catches `post_install` exceptions, so a hook warning is never credited as successful verification or as a failed `brew install`.

Local synthetic checks:

```sh
ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

These tests do not run Homebrew, execute a native payload, read an actual credential or make a network request. Actual Homebrew trust, relocation, signatures, authenticated download and first-run qualification must run on the disposable macOS runner and the qualified candidate. They are not established by these unit tests.
