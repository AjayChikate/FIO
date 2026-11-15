# Lab 10: Measuring Storage Performance with FIO

This repo contains a runner and a small Python results analyzer for `Lab10` assignment. The experiment uses a disposable file, not a raw device or database data directory.

## What the experiment runs

| Case | FIO pattern | Block size | Read share | Queue depths |
|---|---|---:|---:|---|
| A | `randread` | 4 KiB | 100% | 1, 8, 32 |
| B | `randrw` | 4 KiB | 70% | 1, 8, 32 |
| C | `randrw` | 8 KiB | 30% | 1, 8, 32 |
| D | `read` | 256 KiB | 100% | 1, 8, 32 |

Each combination runs three times by default. The default run is 45 seconds with a 5-second ramp period, using one job, `direct=1`, `libaio`, and a 1 GiB test file. 
This is 36 benchmark runs plus initial file preparation. The script keeps each `.fio` job and each raw JSON result.

## Requirements and run instructions

Run the test in Linux or WSL with FIO installed. On Ubuntu/WSL, install FIO:

```bash
sudo apt update
sudo apt install fio
```

In WSL, run the benchmark on the Linux filesystem rather than under `/mnt/c`, whose performance can differ. From the Lab10 folder in Ubuntu/WSL, run:

```bash
bash ./run_fio_lab.sh
```
After all runs finish, copy only the job files, JSON results, and environment record into the Lab10 folder root. The 1 GiB test file stays on the Linux filesystem and is not copied:

```bash
cp -a "$HOME/fio-lab10/jobs" "$HOME/fio-lab10/results" "$HOME/fio-lab10/environment.txt" \
  "/mnt/c/Users/ajayc/OneDrive5/7th sem 4th year/Computer System Design/Lab10/"
```

Then, in PowerShell from this folder, use the project virtual environment to analyze the copied results:

```powershell
& ".\.venv\Scripts\python.exe" ".\analyze_results.py" "."
```

Generated files:

- `environment.txt` — date, FIO version, kernel, OS and filesystem space
- `jobs/*.fio` — exact configuration used for each run
- `results/*.json` — raw FIO output
- `run_results.csv` — metrics for each run
- `summary.csv` — mean and sample standard deviation across repetitions, including FIO's queue-depth histogram buckets
