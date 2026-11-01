# Results

One row per run of `run.sh`, appended by `score.sh`. See the README for what each column means.

| Date | Harness | Steps | Ticked | Step 1 /14 | Step 2 /7 | Step 3 /5 | Other failing | tsc | Outside the plan | Commits / step branches | Guard refusals | `TEST PASS` | Seconds | Tokens in/out |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-01 | pi@e2e3e3a | 1-3 | 1 | 14/14 | 7/7 | 5/5 | 17 | 1 errors | package-lock.json¹ | 1 / 2 | 1 | 0 | 3017 | 2861856/61233 |
| 2026-11-02 | pi@e049e36 | 1-3 | 1 | 14/14 | 6/7 | 3/5 | 6 | 2 errors | none | 1 / 2 | 23 | 1 | 1887 | 5310929/42001 |

¹ Run `20261101-230245-pi`, the first baseline, before the step gates. Session 1 did not stop after step 1 and left step 2 half done; sessions 2 and 3 never ran `branch.sh`, and session 2 deleted `node_modules` and `package-lock.json` and reinstalled on the host. Scored on a copy with the pinned lock file (`score.sh` does that itself since `fbf868f`), so the code's score is the model's and the lock-file change is still listed. The other failing tests are the model's own, flaky because they place zones where the random LandingBase can be: 17 in this re-score, 18 by hand.

Run `20261102-003417-pi`, with the step gates (`feature/step-gates`). Step 1 took 86 s and 14 tool calls: the guard refused its host `npx vitest`, it used `test.sh`, committed, ticked, was refused once after done, and stopped. Step 2 timed out at 30 min (exit 2): it reran one failing test with `--testNamePattern`, alternating with `read`, for 104 calls; the repeated-call breaker refused 19 of them but counts only identical calls in a row. Three `edit` calls were malformed beyond repair (an extra `}` and duplicate `"oldText": null` keys). Step 3 was gated (exit 3): step 2's uncommitted work made `branch.sh` refuse, so the model never ran. Its step 2 and 3 scores are uncommitted work left in the tree.

Both rows are re-scored with the per-result refusal count (`227f9b0`); before it, `score.sh` counted each refusal once per event line, 4–5 times over.
