- Release pipeline: a release ships exactly the commit CI verified, pushes the release commit and tag atomically, and
  drafts the GitHub Release before the push and publishes it after — so the Scoop manifest on `main` never points at a
  zip that is not there. It refuses to release when CI's verdict is unknown, and keeps the release token out of every
  step but the push. A weekly CI run catches an expiring release token in a quiet week.
