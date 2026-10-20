# Changelog

## Unreleased

- Prepare a self-contained Homebrew formula from the candidate's version,
  tarball and manifest pins, and measured macOS floor.
- Fetch private release assets without forwarding credentials on redirects or
  printing response bodies and signed URLs; publish only verified cache bytes.
- Validate the archive before copying the versioned payload and retaining its
  external manifest/install record.
- Keep native post-install verification as the second command in the qualified
  installation sequence, after Homebrew's relocation.

Candidate pins, actual Homebrew qualification and the tap owner's merge are
still required before this preparation supplies an installable release.
