---
name: sync-ark-upstream
description: Catch up the ark.nvim fork with the canonical `posit-dev/ark` repository by configuring `upstream`, fetching `upstream/main`, analyzing divergence, choosing a safe integration strategy, merging or rebasing when appropriate, resolving conflicts, and verifying the result. Use when Codex is asked to sync, catch up, merge, pull in, reconcile, or stay current with "real Ark" or the parent upstream repository.
---

# Sync Ark Upstream

Keep this fork current with `posit-dev/ark` without damaging local history or silently dropping fork-specific behavior.

## Default Assumptions

- Work in the `ark.nvim` repository root.
- Treat `origin` as the user fork and `upstream` as `git@github.com:posit-dev/ark.git`.
- Treat `main` as the integration branch unless the user specifies another branch.
- Prefer a regular merge from `upstream/main` into the current branch when the fork has substantial unpublished or fork-specific history.
- Do not push, force-push, or rewrite remote history unless the user explicitly asks.

## Workflow

1. Confirm repository state first.

- Run `git status --short --branch`.
- If the worktree is dirty, stop and decide whether the user wants to stash, commit, or sync on a separate branch. Do not merge into a dirty tree by default.
- Confirm the current branch and remotes with `git remote -v`.

2. Ensure the canonical upstream remote exists.

- If `upstream` is missing, add `git@github.com:posit-dev/ark.git` as `upstream`.
- Fetch `upstream` before making any strategy decision.

3. Measure divergence instead of guessing.

- Use `git rev-list --left-right --count HEAD...upstream/main`.
- Use `git merge-base HEAD upstream/main`.
- Read `git log --oneline HEAD..upstream/main` to see what is missing from the fork.
- Read `git log --oneline upstream/main..HEAD` to estimate how expensive rebasing would be.
- Skim `git diff --stat HEAD..upstream/main` to see which subsystems upstream touched.

4. Choose the integration strategy deliberately.

- Default to `merge --no-ff upstream/main` for this project.
- Prefer a merge when the fork is meaningfully ahead of upstream, when the branch is already shared, or when local commits encode fork-specific product behavior.
- Consider a rebase only when all of these are true: the branch is effectively private, the local ahead count is small, the user explicitly wants linear history, and conflict replay cost is likely low.
- If the divergence is large and risky, create a dedicated sync branch first and merge there before touching `main`.

5. Create a restore point before integrating.

- Tag the pre-sync tip with a dated local tag such as `pre-upstream-merge-YYYY-MM-DD`.
- If the integration is expected to be messy, create a branch such as `sync/upstream-YYYY-MM-DD` as well.

6. Integrate upstream.

- For the normal case, run `git merge --no-ff upstream/main`.
- If Git stops for conflicts, resolve them file by file and continue the merge.
- Do not use `-X ours` or `-X theirs` globally. This fork diverges in meaningful ways and blanket strategies hide real regressions.

## Conflict Rules

- Keep upstream bug fixes and performance fixes by default unless they directly break intentional fork behavior.
- When upstream renames or moves files, accept the upstream path/layout first, then replay local behavior on top of the new location.
- For docs, workflow notes, and local repo instructions, preserve fork-specific documentation unless upstream text clearly supersedes it.
- For startup, session, REPL, completion, and editor integration code, preserve the fork's intended UX and local integrations, but port upstream correctness or performance fixes into the local shape.
- If a conflict shows that the fork has a long-lived patch that upstream has independently solved more elegantly, prefer the upstream design and keep only the minimal fork-specific delta.
- In some cases an upstream fix may adress a the bug targetted by a local patch. Choose which ever version is more elegant and easy to maintian.

## Verification

Verify the changed area, not just the merge mechanics.

- Run `git status --short --branch` after the merge and confirm the worktree is clean.
- Inspect the new tip with `git log --oneline --graph --max-count=8`.
- Run the narrowest relevant tests for the upstream-only commits you just imported.
- If upstream changed data explorer scheduling, REPL prioritization, completions, startup, or similar hot paths, run targeted tests in those areas before the complete suites.
  Work isn't done until tests are all green.

## Toolchain Rule

- Expect upstream Ark bumps to change the minimum supported Rust version.
- If plain `cargo test` fails because local stable Rust is too old, check installed toolchains before stopping.
- If a newer local toolchain already exists, use it for verification and report the version mismatch clearly.
- Do not silently install toolchains or change the user's default toolchain unless asked.

## Close-Out

- Summarize the exact divergence you started with, the strategy chosen, whether conflicts occurred, and what was verified.
- Call out any remaining follow-up such as pushing to `origin`, opening a PR, or aligning the repo toolchain metadata.
- Leave the branch unpushed unless the user asked for the push.

## Project Policy

- For `ark.nvim`, the standing default is: fetch `upstream`, inspect divergence, create a restore tag, merge `upstream/main`, resolve conflicts conservatively, run targeted verification, and only then offer to push.
- Use a rebase only as an explicit exception, not the routine catch-up path.
