---
status: accepted
---

# Model defaults are data, and a user contract holds them

The kit used to hard-code each kind's default model in `executor.sh`, so a
new model meant a tower release, and with cursor, whose model list changes
monthly, that stopped being tolerable. Every model default now lives in one
data file in the kit, keyed per kind (`EXECUTOR_MODEL_<KIND>`,
`REVIEWER_MODEL_<KIND>`), and a user contract at
`~/.config/tower/orchestrate` takes the same keys. Precedence: the
environment of a kit call, then the repo contract, then the user contract,
then the kit's file. Per-kind keys are needed because one `EXECUTOR_MODEL`
cannot serve a mixed run. We rejected shipping no defaults at all (each
harness's own default): a fresh install would then run lanes on whatever
the harness picks, and the Reviewer rule could not name a model.
