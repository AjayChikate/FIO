#!/usr/bin/env bash
set -Eeuo pipefail

LAB_DIR="${FIO_LAB_DIR:-"$HOME/fio-lab10"}"
DATA_FILE="$LAB_DIR/db-test.bin"
MARKER="$LAB_DIR/.fio-lab-managed"
FILE_SIZE_GIB="${FIO_FILE_SIZE_GIB:-1}"
RUNTIME="${FIO_RUNTIME:-45}"
RAMP_TIME="${FIO_RAMP_TIME:-5}"
REPETITIONS="${FIO_REPETITIONS:-3}"
ENGINE="${FIO_ENGINE:-libaio}"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ "$(uname -s)" == "Linux" ]] || die "Run this script in Linux or WSL, not Windows PowerShell."
command -v fio >/dev/null 2>&1 || die "fio is not installed. Install it with: sudo apt install fio"
command -v stat >/dev/null 2>&1 || die "stat is required."

[[ "$LAB_DIR" == /* ]] || die "FIO_LAB_DIR must be an absolute path."
[[ "$LAB_DIR" != "/" && "$LAB_DIR" != "$HOME" ]] || die "Use a dedicated lab directory, not / or your home directory."
[[ "$FILE_SIZE_GIB" =~ ^[1-9][0-9]*$ ]] || die "FIO_FILE_SIZE_GIB must be a positive whole number."
[[ "$RUNTIME" =~ ^[1-9][0-9]*$ ]] || die "FIO_RUNTIME must be a positive whole number."
[[ "$RAMP_TIME" =~ ^[0-9]+$ ]] || die "FIO_RAMP_TIME must be zero or a positive whole number."
[[ "$REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die "FIO_REPETITIONS must be a positive whole number."

if [[ -L "$LAB_DIR" ]]; then
    die "The lab directory must not be a symbolic link: $LAB_DIR"
fi
mkdir -p -- "$LAB_DIR"

if [[ ! -f "$MARKER" ]]; then
    first_entry="$(find "$LAB_DIR" -mindepth 1 -maxdepth 1 -print -quit)"
    [[ -z "$first_entry" ]] || die "The lab directory is not empty and has no lab marker. Choose a new FIO_LAB_DIR."
    printf 'Created by run_fio_lab.sh\n' > "$MARKER"
fi

expected_bytes=$((FILE_SIZE_GIB * 1024 * 1024 * 1024))
if [[ -e "$DATA_FILE" ]]; then
    [[ -f "$DATA_FILE" && ! -L "$DATA_FILE" ]] || die "The test target exists but is not a regular file: $DATA_FILE"
    actual_bytes="$(stat -c '%s' -- "$DATA_FILE")"
    [[ "$actual_bytes" -eq "$expected_bytes" ]] || die "Existing test file has size $actual_bytes bytes; expected $expected_bytes. Preserve it and choose a new lab directory."
else
    printf 'Preparing a %s GiB disposable test file at %s\n' "$FILE_SIZE_GIB" "$DATA_FILE"
    fio --name=prepare \
        --filename="$DATA_FILE" \
        --ioengine="$ENGINE" \
        --direct=1 \
        --rw=write \
        --bs=1m \
        --size="${FILE_SIZE_GIB}g" \
        --end_fsync=1 \
        --group_reporting=1
    [[ -f "$DATA_FILE" ]] || die "FIO did not create the expected test file."
    actual_bytes="$(stat -c '%s' -- "$DATA_FILE")"
    [[ "$actual_bytes" -eq "$expected_bytes" ]] || die "Prepared test file has size $actual_bytes bytes; expected $expected_bytes."
fi

mkdir -p -- "$LAB_DIR/jobs" "$LAB_DIR/results"
{
    printf 'Date: %s\n' "$(date --iso-8601=seconds)"
    printf 'FIO version: '
    fio --version
    printf 'Kernel: '
    uname -a
    printf 'OS release:\n'
    if [[ -r /etc/os-release ]]; then
        cat /etc/os-release
    else
        printf 'Unavailable\n'
    fi
    printf '\nCPU model: '
    awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo
    printf 'Logical CPUs: '
    nproc
    printf 'Memory: '
    awk '/MemTotal/ {printf "%.1f GiB\n", $2 / 1048576}' /proc/meminfo
    printf '\nFilesystem space for lab directory:\n'
    df -h "$LAB_DIR"
    printf '\nFIO engine: %s\n' "$ENGINE"
    printf 'Test file: %s (%s GiB)\n' "$DATA_FILE" "$FILE_SIZE_GIB"
    printf 'Runtime: %s seconds; ramp time: %s seconds; repetitions: %s\n' "$RUNTIME" "$RAMP_TIME" "$REPETITIONS"
} > "$LAB_DIR/environment.txt"

write_job() {
    local case_id="$1" pattern="$2" block_size="$3" mix_read="$4" depth="$5" repetition="$6"
    local name="case${case_id}_qd${depth}_rep${repetition}"
    local job_file="$LAB_DIR/jobs/${name}.fio"

    {
        printf '[global]\n'
        printf 'ioengine=%s\n' "$ENGINE"
        printf 'direct=1\n'
        printf 'size=%sg\n' "$FILE_SIZE_GIB"
        printf 'runtime=%s\n' "$RUNTIME"
        printf 'time_based=1\n'
        printf 'ramp_time=%s\n' "$RAMP_TIME"
        printf 'group_reporting=1\n'
        printf 'filename=%s\n' "$DATA_FILE"
        printf 'percentile_list=50:95:99\n'
        printf '\n[database-workload]\n'
        printf 'rw=%s\n' "$pattern"
        printf 'bs=%s\n' "$block_size"
        printf 'iodepth=%s\n' "$depth"
        printf 'numjobs=1\n'
        if [[ "$pattern" == "randrw" ]]; then
            printf 'rwmixread=%s\n' "$mix_read"
        fi
    } > "$job_file"
}

run_case() {
    local case_id="$1" description="$2" pattern="$3" block_size="$4" mix_read="$5"
    local depth repetition name job_file json_file

    for depth in 1 8 32; do
        for ((repetition = 1; repetition <= REPETITIONS; repetition++)); do
            name="case${case_id}_qd${depth}_rep${repetition}"
            job_file="$LAB_DIR/jobs/${name}.fio"
            json_file="$LAB_DIR/results/${name}.json"
            write_job "$case_id" "$pattern" "$block_size" "$mix_read" "$depth" "$repetition"
            if [[ -s "$json_file" ]]; then
                printf 'Skipping completed result %s\n' "$json_file"
                continue
            fi
            printf '\nRunning %s (%s), queue depth %s, repetition %s/%s\n' \
                "$case_id" "$description" "$depth" "$repetition" "$REPETITIONS"
            fio --parse-only "$job_file"
            fio "$job_file" --output="$json_file" --output-format=json
        done
    done
}

printf 'FIO results will be saved under: %s\n' "$LAB_DIR"
printf 'Only the disposable file %s is used as the I/O target.\n' "$DATA_FILE"

run_case A "point lookups" "randread" "4k" 100
run_case B "update-heavy mixed random" "randrw" "4k" 70
run_case C "read-heavy mixed random" "randrw" "8k" 30
run_case D "sequential scan" "read" "256k" 100

printf '\nAll runs completed. Analyze results with:\n'
printf 'python3 analyze_results.py "%s"\n' "$LAB_DIR"
