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

check_file() {
    local path=$1
    local label=$2
    if [[ -f "$path" ]]; then
        pass "$label"
    else
        fail "$label (missing: $path)"
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
