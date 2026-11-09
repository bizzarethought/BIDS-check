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
    echo "PASS: $*"
    passed=$((passed + 1))
}

fail() {
    echo "FAIL: $*"
    failed=$((failed + 1))
}

warn() {
    echo "WARN: $*"
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

check_intended_for() {
    local json_file=$1
    local participant_dir=$2
    local subject=$3
    local session=$4

    if ! python3 - "$json_file" "$participant_dir" "$subject" "$session" <<'PY'
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
if not isinstance(intended, list) or not intended:
    print("missing or empty IntendedFor")
    raise SystemExit(1)

for target in intended:
    expected_prefix = f"{session}/func/{subject}_{session}_task-"
    if not isinstance(target, str) or not target.startswith(expected_prefix) or not target.endswith("_bold.nii.gz"):
        print(f"invalid functional target: {target}")
        raise SystemExit(1)
    if not os.path.isfile(os.path.join(participant_dir, target)):
        print(f"missing target: {target}")
        raise SystemExit(1)
PY
    then
        fail "fieldmap IntendedFor invalid: $json_file"
    else
        pass "fieldmap IntendedFor valid: $(basename "$json_file")"
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
    func_count=$(find "$func" -maxdepth 1 -type f 2>/dev/null | wc -l)
    info "$SUBJECT/$session func contains $func_count files; complete expected pattern is 42"

    for file in \
        "${SUBJECT}_${session}_run-01_T1w.nii.gz" \
        "${SUBJECT}_${session}_run-01_T1w.json" \
        "${SUBJECT}_${session}_run-02_T1w.nii.gz" \
        "${SUBJECT}_${session}_run-02_T1w.json"; do
        check_file "$anat/$file" "anat file $file"
    done

    for task in bandit circle ghost mdp1 mdp2; do
        label=$task
        for file in \
            "${SUBJECT}_${session}_task-${task}_run-01_events.tsv" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-1_bold.nii.gz" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-1_bold.json" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-2_bold.nii.gz" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-2_bold.json" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-3_bold.nii.gz" \
            "${SUBJECT}_${session}_task-${task}_run-01_echo-3_bold.json"; do
            check_file "$func/$file" "func $label file $file"
        done
    done

    berry_label=
    for candidate in berry coin; do
        if compgen -G "$func/${SUBJECT}_${session}_task-${candidate}_run-01_*" >/dev/null; then
            if [[ -n "$berry_label" ]]; then
                warn "$SUBJECT/$session contains both task-berry and task-coin"
            else
                berry_label=$candidate
            fi
        fi
    done

    if [[ -z "$berry_label" ]]; then
        fail "func berry/coin task is missing"
    else
        for file in \
            "${SUBJECT}_${session}_task-${berry_label}_run-01_events.tsv" \
            "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-1_bold.nii.gz" \
            "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-1_bold.json" \
            "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-2_bold.nii.gz" \
            "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-2_bold.json" \
            "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-3_bold.nii.gz" \
            "${SUBJECT}_${session}_task-${berry_label}_run-01_echo-3_bold.json"; do
            check_file "$func/$file" "func berry/coin (task-$berry_label) file $file"
        done
    fi

    for direction in AP PA; do
        if compgen -G "$fmap/*_dir-${direction}_epi.nii.gz" >/dev/null; then
            pass "fmap has $direction NIfTI"
        else
            fail "fmap has no $direction NIfTI"
        fi
        if compgen -G "$fmap/*_dir-${direction}_epi.json" >/dev/null; then
            pass "fmap has $direction JSON"
        else
            fail "fmap has no $direction JSON"
        fi
    done

    fmap_json_count=0
    for fmap_json in "$fmap"/*_dir-*_epi.json; do
        [[ -f "$fmap_json" ]] || continue
        fmap_json_count=$((fmap_json_count + 1))
        check_intended_for "$fmap_json" "$BIDS_ROOT/$SUBJECT" "$SUBJECT" "$session"
    done
    if [[ "$fmap_json_count" -eq 0 ]]; then
        fail "fmap has no JSON files to validate"
    fi

    if [[ -d "$BIDS_ROOT/derivatives/$SUBJECT/$session/anat" ]]; then
        nm_count=$(find "$BIDS_ROOT/derivatives/$SUBJECT/$session/anat" -maxdepth 1 -type f \
            \( -name '*_NM.nii.gz' -o -name '*_NM.json' \) | wc -l)
        if [[ "$nm_count" -eq 8 ]]; then
            pass "derivatives NM data has 8 files"
        else
            warn "derivatives NM data has $nm_count files; expected 8 when available"
        fi
    else
        warn "derivatives NM data is absent; verify external scan records"
    fi
done

echo
echo "Summary: $passed passed, $failed failed, $warnings warnings"
if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
exit 0
