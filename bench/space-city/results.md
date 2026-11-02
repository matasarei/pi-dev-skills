# Results

One row per run of `run.sh`, appended by `score.sh`. See the README for what each column means.

| Date | Harness | Steps | Ticked | Step 1 /14 | Step 2 /7 | Step 3 /5 | Other failing | tsc | Outside the plan | Commits / step branches | Guard refusals | `TEST PASS` | Seconds | Tokens in/out |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-01 | pi@e2e3e3a | 1-3 | 1 | 14/14 | 7/7 | 5/5 | 18 | 1 errors | package-lock.json¹ | 1 / 2 | 5 | 14 | 3017 | 2861856/61233 |

¹ Run `20261101-230245-pi`, the first baseline. Session 2 deleted `node_modules` and `package-lock.json` and reinstalled on the host, which broke the container the tests run in. The row was re-scored on a copy with the lock file restored and the dependencies reinstalled in the container. The lock-file change is the model's, so it is listed as outside the plan. The 18 other failing tests are the model's own, flaky because they place zones where the random LandingBase can be.
