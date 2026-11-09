#!/usr/bin/env bash
set -u

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 BIDS_ROOT SUBJECT [SESSION]" >&2
    exit 2
fi

BIDS_ROOT=${1%/}
SUBJECT=$2
SESSION=${3:-}

if [[ "$SUBJECT" != sub-* ]]; then
    SUBJECT="sub-$SUBJECT"
fi
if [[ -n "$SESSION" && "$SESSION" != ses-* ]]; then
    SESSION="ses-$SESSION"
fi

if [[ ! -d "$BIDS_ROOT/$SUBJECT" ]]; then
    echo "FAIL: participant directory not found: $BIDS_ROOT/$SUBJECT"
    exit 1
fi

if [[ -n "$SESSION" ]]; then
    sessions=("$BIDS_ROOT/$SUBJECT/$SESSION")
else
    mapfile -t sessions < <(
        find "$BIDS_ROOT/$SUBJECT" -mindepth 1 -maxdepth 1 -type d -name 'ses-*' -printf '%p\n' | sort
    )
fi

if [[ ${#sessions[@]} -eq 0 ]]; then
    echo "FAIL: no sessions found for $SUBJECT"
    exit 1
fi

passed=0
failed=0
warnings=0

pass() {
    passed=$((passed + 1))
}

fail() {
    failures+=("$*")
    failed=$((failed + 1))
}

warn() {
    warnings_list+=("$*")
    warnings=$((warnings + 1))
}

info() {
    echo "INFO: $*"
}

check_file() {
    local path=$1
    local label=$2
    if [[ -f "$path" ]]; then
        pass "$label"
    else
        fail "$label (missing: $path)"
    fi
}

failures=()
warnings_list=()

check_file_identity() {
    local file=$1
    local subject=$2
    local session=$3
    local filename
    filename=$(basename "$file")
    if [[ "$filename" != "$subject"_* ]]; then
        fail "subject ID mismatch: $filename is under $subject"
    elif [[ "$filename" != *_"$session"_* ]]; then
        fail "session ID mismatch: $filename is under $session"
    fi
}

check_intended_for() {
    local json_file=$1
    local participant_dir=$2
    local subject=$3
    local session=$4

    if reason=$(python3 - "$json_file" "$participant_dir" "$subject" "$session" 2>&1 <<'PY'
import json
import os
import sys

json_file, participant_dir, subject, session = sys.argv[1:]
try:
    with open(json_file, encoding="utf-8") as stream:
        metadata = json.load(stream)
except (OSError, json.JSONDecodeError) as error:
    print(f"invalid JSON ({error})")
    raise SystemExit(1)

intended = metadata.get("IntendedFor")
if isinstance(intended, str):
    intended = [intended]
if not isinstance(intended, list) or not intended:
    print("missing or empty IntendedFor")
    raise SystemExit(1)

errors = []
for target in intended:
    if not isinstance(target, str):
        errors.append(f"invalid target: {target}")
        continue
    if target.startswith("bids::"):
        target = target[6:]
    if target.startswith(subject + "/"):
        target = target[len(subject) + 1:]
    expected_prefix = f"{session}/func/{subject}_{session}_task-"
    if not target.startswith(expected_prefix) or not target.endswith("_bold.nii.gz"):
        errors.append(f"invalid target: {target}")
    elif not os.path.isfile(os.path.join(participant_dir, target)):
        errors.append(f"missing target: {target}")
if errors:
    print("; ".join(errors))
    raise SystemExit(1)
PY
    ); then
        pass "fieldmap IntendedFor valid"
    else
        fail "fieldmap $(basename "$json_file"): $reason"
        echo "FAIL: fieldmap $(basename "$json_file"): $reason"
    fi
}

for session_dir in "${sessions[@]}"; do
    if [[ ! -d "$session_dir" ]]; then
        fail "session directory not found: $session_dir"
        continue
    fi

    session=$(basename "$session_dir")
    echo
    echo "Checking $SUBJECT/$session"

    anat="$session_dir/anat"
    func="$session_dir/func"
    fmap="$session_dir/fmap"
    func_count=0
    if [[ -d "$func" ]]; then
        func_count=$(find "$func" -maxdepth 1 -type f | wc -l)
    else
        fail "func folder is missing"
        echo "FAIL: func folder is missing"
    fi
    info "$SUBJECT/$session func contains $func_count files; complete expected pattern is 42"
    extra_runs=()
    while IFS= read -r filename; do
        if [[ "$filename" =~ _run-([0-9]+)_ ]] && [[ "${BASH_REMATCH[1]}" != "01" ]]; then
            extra_runs+=("$filename")
        fi
    done < <([[ -d "$func" ]] && find "$func" -maxdepth 1 -type f -printf '%f\n' | sort)
    if [[ ${#extra_runs[@]} -gt 0 ]]; then
        warn "$SUBJECT/$session has additional functional run files"
        echo "WARN: func has ${#extra_runs[@]} files from runs other than run-01"
    fi

    anat_missing=()
    for file in \
        "${SUBJECT}_${session}_run-01_T1w.nii.gz" \
        "${SUBJECT}_${session}_run-01_T1w.json" \
        "${SUBJECT}_${session}_run-02_T1w.nii.gz" \
        "${SUBJECT}_${session}_run-02_T1w.json"; do
        if [[ ! -f "$anat/$file" ]]; then
            anat_missing+=("$file")
            fail "anat: missing $file"
        else
            pass "anat: $file"
        fi
    done
    if [[ ${#anat_missing[@]} -eq 0 ]]; then
        echo "PASS: anat (4/4 expected files)"
    else
        echo "FAIL: anat (${#anat_missing[@]} missing: ${anat_missing[*]})"
    fi
    if [[ -d "$anat" ]]; then
        while IFS= read -r file; do
            check_file_identity "$file" "$SUBJECT" "$session"
        done < <(find "$anat" -maxdepth 1 -type f -printf '%p\n' | sort)
    fi

    for task in bandit circle ghost mdp1 mdp2; do
        task_missing=()
        for file in \
            "${SUBJECT}_${session}_task-${task}_run-01_events.tsv" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-1_bold.nii.gz" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-1_bold.json" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-2_bold.nii.gz" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-2_bold.json" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-3_bold.nii.gz" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-3_bold.json"; do
            if [[ ! -f "$func/$file" ]]; then
                task_missing+=("$file")
                fail "func $task: missing $file"
            else
                pass "func $task: $file"
            fi
        done
        if [[ ${#task_missing[@]} -eq 0 ]]; then
            echo "PASS: func $task (7/7 expected files)"
        else
            echo "FAIL: func $task (${#task_missing[@]} missing)"
            printf '      - %s\n' "${task_missing[@]}"
        fi
    done

    berry_labels=()
    for candidate in berry coin; do
        if compgen -G "$func/${SUBJECT}_${session}_task-${candidate}_run-01_*" >/dev/null; then
            berry_labels+=("$candidate")
        fi
    done

    if [[ ${#berry_labels[@]} -eq 0 ]]; then
        fail "func berry/coin: task-berry and task-coin are missing"
        echo "FAIL: func berry/coin (task-berry or task-coin not found)"
    else
        if [[ ${#berry_labels[@]} -eq 2 ]]; then
            warn "$SUBJECT/$session contains both task-berry and task-coin"
            echo "WARN: both task-berry and task-coin found; checking both"
        fi
        for berry_label in "${berry_labels[@]}"; do
            berry_missing=()
            for file in \
                "${SUBJECT}_${session}_task-${berry_label}_run-01_events.tsv" \
                "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-1_bold.nii.gz" \
                "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-1_bold.json" \
                "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-2_bold.nii.gz" \
                "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-2_bold.json" \
                "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-3_bold.nii.gz" \
                "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-3_bold.json"; do
                if [[ ! -f "$func/$file" ]]; then
                    berry_missing+=("$file")
                    fail "func berry/coin task-$berry_label: missing $file"
                else
                    pass "func berry/coin task-$berry_label: $file"
                fi
            done
            if [[ ${#berry_missing[@]} -eq 0 ]]; then
                echo "PASS: func berry/coin (task-$berry_label, 7/7 expected files)"
            else
                echo "FAIL: func berry/coin (task-$berry_label, ${#berry_missing[@]} missing)"
                printf '      - %s\n' "${berry_missing[@]}"
            fi
        done
    fi
    if [[ -d "$func" ]]; then
        while IFS= read -r file; do
            check_file_identity "$file" "$SUBJECT" "$session"
        done < <(find "$func" -maxdepth 1 -type f -printf '%p\n' | sort)
    fi

    fmap_missing=()
    for direction in AP PA; do
        if compgen -G "$fmap/*_dir-${direction}_epi.nii.gz" >/dev/null; then
            pass "fmap $direction NIfTI"
        else
            fmap_missing+=("$direction NIfTI")
            fail "fmap: missing $direction NIfTI"
        fi
        if compgen -G "$fmap/*_dir-${direction}_epi.json" >/dev/null; then
            pass "fmap $direction JSON"
        else
            fmap_missing+=("$direction JSON")
            fail "fmap: missing $direction JSON"
        fi
    done
    if [[ ${#fmap_missing[@]} -eq 0 ]]; then
        echo "PASS: fmap (AP/PA NIfTI and JSON present)"
    else
        echo "FAIL: fmap missing: ${fmap_missing[*]}"
    fi
    if [[ -d "$fmap" ]]; then
        while IFS= read -r file; do
            check_file_identity "$file" "$SUBJECT" "$session"
        done < <(find "$fmap" -maxdepth 1 -type f -printf '%p\n' | sort)
    fi

    fmap_json_count=0
    for fmap_json in "$fmap"/*_dir-*_epi.json; do
        [[ -f "$fmap_json" ]] || continue
        fmap_json_count=$((fmap_json_count + 1))
        check_intended_for "$fmap_json" "$BIDS_ROOT/$SUBJECT" "$SUBJECT" "$session"
    done
    if [[ "$fmap_json_count" -eq 0 ]]; then
        info "fmap: no JSON files available for IntendedFor validation"
    fi

    if [[ -d "$BIDS_ROOT/derivatives/$SUBJECT/$session/anat" ]]; then
        nm_count=$(find "$BIDS_ROOT/derivatives/$SUBJECT/$session/anat" -maxdepth 1 -type f \
            \( -name '*_NM.nii.gz' -o -name '*_NM.json' \) | wc -l)
        if [[ "$nm_count" -eq 8 ]]; then
            pass "derivatives NM data"
            echo "PASS: derivatives NM (8/8 expected files)"
        else
            warn "derivatives NM data has $nm_count files; expected 8 when available"
            echo "WARN: derivatives NM ($nm_count/8 files; verify if NM was scanned)"
        fi
    else
        warn "derivatives NM data is absent; verify external scan records"
        echo "WARN: derivatives NM (not present; verify if NM was scanned)"
    fi
done

echo
if [[ ${#failures[@]} -gt 0 ]]; then
    echo "Failure details:"
    printf '  - %s\n' "${failures[@]}"
fi
if [[ ${#warnings_list[@]} -gt 0 ]]; then
    echo "Warning details:"
    printf '  - %s\n' "${warnings_list[@]}"
fi
echo "Summary: $passed checks passed, $failed checks failed, $warnings warnings"
if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
exit 0
