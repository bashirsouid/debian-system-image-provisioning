# brave-repo

Repo-only base profile for Brave's apt repository. Ships `brave.sources` and
the `brave-browser-archive-keyring.gpg` signing key. No packages.

You don't select it directly: the Brave profiles declare `requires=brave-repo`
and the resolver pulls it in once. Each installs a *different* package from the
same repo, so they share the repo but not the package:

- `brave-browser` → installs `brave-browser`.
- `brave-origin` → installs `brave-origin`.

> Do not add a bare `Packages=` here — an empty list assignment resets mkosi's
> whole package list.

No secret values are required.
