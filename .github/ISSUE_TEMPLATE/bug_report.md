---
name: Bug report
about: Report incorrect or unreliable ark.nvim behavior
title: ""
labels: bug
assignees: ""
---

Thanks for helping improve ark.nvim. Please search existing issues first and
test the latest release in the same release channel when practical.

## What happened?

Describe the visible behavior and what you expected instead.

## Minimal reproduction

Include the smallest R/Rmd/Qmd example and the exact Neovim actions or commands
that reproduce the problem. State whether it happens with the tmux backend, the
built-in terminal backend, or both.

## Support report

Run `:Ark report`, review the preview, and paste it here. The report is designed
to omit source text, R values, arbitrary environment variables, and auth tokens,
but you should still review it before sharing.

```text
Paste the reviewed report here.
```

## Additional evidence

For crashes, hangs, or performance regressions, include only the relevant Ark
log excerpt and approximate timing. Do not post authentication tokens, private
R data, or unrelated system logs.

## Regression information

If this worked previously, name the last known-good Ark release or commit.
