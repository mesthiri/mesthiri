# Turning it off

```bash
mesthiri uninstall owner/repo --operator "Your Name <you@example.org>"
```

Opens a pull request removing the shim workflow and `.mesthiri/`. Merging
it stops everything. Labels mesthiri applied stay where they are, because
they are your repository's data, not mesthiri's; delete them if you want
them gone.

To stop it right now without waiting for a review, disable the workflow in
the Actions tab, or revoke the Apps' installation. Nothing keeps running
somewhere else, because there is no somewhere else.
