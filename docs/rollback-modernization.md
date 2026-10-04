# Modernization rollback

The immutable starting point for this modernization is:

- branch: `backup/modern-my-wave-home-before-full-refactor`
- commit: `ea17089219ad5197de0e43cc6844e5644575cd75`

## Restore the complete pre-refactor state

```bash
git fetch origin
git checkout feature/modern-my-wave-home
git reset --hard origin/backup/modern-my-wave-home-before-full-refactor
git push --force-with-lease origin feature/modern-my-wave-home
```

Use `--force-with-lease`, never plain `--force`, so newer remote work is not overwritten
silently.

## Undo only one change

Prefer a normal revert when only one improvement is unwanted:

```bash
git checkout feature/modern-my-wave-home
git pull --ff-only
git revert <commit-sha>
git push
```

This preserves later work and records the rollback in history.