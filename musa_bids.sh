#!/usr/bin/env bash
set -u

# Post-heudiconv checks for one MUSA participant or session.
# Required current layout: 4 T1w files, six 7-file task runs, and AP/PA
# fieldmaps. NM derivatives are optional because not every participant had NM.

if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq is required; run this script on Anvil." >&2
    exit 2
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 BIDS_ROOT SUBJECT [SESSION]" >&2
    exit 2
fi

BIDS_ROOT=${1%/}
SUBJECT=$2
SESSION=${3:-}
[[ "$SUBJECT" == sub-* ]] || SUBJECT="sub-$SUBJECT"
[[ -z "$SESSION" || "$SESSION" == ses-* ]] || SESSION="ses-$SESSION"

if [[ ! -d "$BIDS_ROOT/$SUBJECT" ]]; then
    echo "FAIL: participant directory not found: $BIDS_ROOT/$SUBJECT"
    exit 1
fi

if [[ -n "$SESSION" ]]; then
    sessions=("$BIDS_ROOT/$SUBJECT/$SESSION")
else
    mapfile -t sessions < <(
        find "$BIDS_ROOT/$SUBJECT" -mindepth 1 -maxdepth 1 -type d \
            -name 'ses-*' -printf '%p\n' | sort
    )
fi

if [[ ${#sessions[@]} -eq 0 ]]; then
    echo "FAIL: no sessions found for $SUBJECT"
    exit 1
fi

passed=0
failed=0
warnings=0
failures=()
warnings_list=()

pass() { passed=$((passed + 1)); }
fail() { failures+=("$*"); failed=$((failed + 1)); }
warn() { warnings_list+=("$*"); warnings=$((warnings + 1)); }
info() { echo "INFO: $*"; }

check_identity() {
    local file=$1 subject=$2 session=$3 name
    name=$(basename "$file")
    [[ "$name" == "$subject"_* ]] || fail "subject ID mismatch: $name is under $subject"
    [[ "$name" == *_"$session"_* ]] || fail "session ID mismatch: $name is under $session"
}

check_intended_for() {
    local json_file=$1 participant_dir=$2 subject=$3 session=$4 reason

    reason=$(jq -r --arg subject "$subject" --arg session "$session" '
        def targets:
            .IntendedFor
            | if type == "string" then [.] else . end;
        if has("IntendedFor") | not then
            "missing IntendedFor"
        elif (.IntendedFor | type) == "array" and (.IntendedFor | length) == 0 then
            "empty IntendedFor"
        elif (.IntendedFor | type) != "array" and (.IntendedFor | type) != "string" then
            "IntendedFor must be a string or array"
        else
            [targets[] as $target
             | ($target | sub("^bids::"; "") | sub("^" + $subject + "/"; "")) as $path
             | if ($path | startswith($session + "/func/" + $subject + "_" + $session + "_task-") | not)
                  or ($path | endswith("_bold.nii.gz") | not) then
                   "invalid target: " + $path
               else empty end]
            | if length == 0 then empty else join("; ") end
        end
    ' "$json_file" 2>&1)
    if [[ -z "$reason" ]]; then
        while IFS= read -r target; do
            [[ -z "$target" ]] && continue
            target=${target#bids::}
            target=${target#"$subject"/}
            if [[ ! -f "$participant_dir/$target" ]]; then
                reason="missing target: $target"
                break
            fi
        done < <(jq -r '
            .IntendedFor
            | if type == "string" then . else .[] end
        ' "$json_file" 2>/dev/null)
    fi
    if [[ -z "$reason" ]]; then
        pass
    else
        fail "fieldmap $(basename "$json_file"): $reason"
        echo "FAIL: fieldmap $(basename "$json_file"): $reason"
    fi
}

check_sidecar() {
    local dir=$1 stem=$2
    if [[ -f "$dir/$stem.nii.gz" && -f "$dir/$stem.json" ]]; then
        pass
        return 0
    fi
    return 1
}

check_task() {
    local func=$1 subject=$2 session=$3 label=$4 display=${5:-$4}
    local missing=() stem file

    for stem in \
        "${subject}_${session}_task-${label}_run-01_echo-1_bold" \
        "${subject}_${session}_task-${label}_run-01_echo-2_bold" \
        "${subject}_${session}_task-${label}_run-01_echo-3_bold"; do
        if ! check_sidecar "$func" "$stem"; then
            missing+=("$stem.nii.gz and/or $stem.json")
            fail "func $display: missing $stem image or metadata"
        fi
    done

    file="${subject}_${session}_task-${label}_run-01_events.tsv"
    if [[ ! -f "$func/$file" ]]; then
        missing+=("$file")
        fail "func $display: missing events file"
    else
        pass
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "PASS: func $display (3 echoes and events)"
    else
        echo "FAIL: func $display (${#missing[@]} missing)"
        printf '      - %s\n' "${missing[@]}"
    fi
}

check_anat() {
    local anat=$1 subject=$2 session=$3
    local expected=(
        "${subject}_${session}_run-01_T1w.nii.gz"
        "${subject}_${session}_run-01_T1w.json"
        "${subject}_${session}_run-02_T1w.nii.gz"
        "${subject}_${session}_run-02_T1w.json"
    )
    local missing=() file

    for file in "${expected[@]}"; do
        if [[ ! -f "$anat/$file" ]]; then
            missing+=("$file")
            fail "anat: missing $file"
        else
            pass
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "PASS: anat (2 T1w runs with metadata)"
    else
        echo "FAIL: anat (${#missing[@]} missing)"
        printf '      - %s\n' "${missing[@]}"
    fi
}

check_fmap() {
    local fmap=$1 subject=$2 session=$3 participant_dir=$4
    local missing=() direction file json_count=0

    for direction in AP PA; do
        for file in "$fmap"/*_dir-"$direction"_epi.nii.gz \
                    "$fmap"/*_dir-"$direction"_epi.json; do
            [[ -f "$file" ]] && continue
            missing+=("$direction $( [[ "$file" == *.json ]] && echo metadata || echo image )")
            fail "fmap: missing ${missing[-1]}"
        done
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "PASS: fmap (AP/PA images and metadata)"
    else
        echo "FAIL: fmap missing: ${missing[*]}"
    fi

    for json in "$fmap"/*_dir-*_epi.json; do
        [[ -f "$json" ]] || continue
        json_count=$((json_count + 1))
        check_intended_for "$json" "$participant_dir" "$subject" "$session"
    done
    ((json_count > 0)) || info "fmap: no metadata files available for IntendedFor check"
}

check_nm() {
    local nm_dir=$1 count
    if [[ ! -d "$nm_dir" ]]; then
        warn "NM data not found; verify whether NM scanning was done"
        echo "WARN: NM data not found"
        return
    fi
    count=$(find "$nm_dir" -maxdepth 1 -type f \
        \( -name '*_NM.nii.gz' -o -name '*_NM.json' \) | wc -l)
    if [[ "$count" -eq 8 ]]; then
        pass
        echo "PASS: NM data (8 files)"
    else
        warn "NM data has $count files; expected 8 when available"
        echo "WARN: NM data has $count files"
    fi
}

check_session() {
    local session_dir=$1
    local session=$(basename "$session_dir")
    local anat="$session_dir/anat"
    local func="$session_dir/func"
    local fmap="$session_dir/fmap"
    local func_count extra_runs=() filename label

    echo
    echo "Checking $SUBJECT/$session"
    if [[ ! -d "$session_dir" ]]; then
        fail "session directory not found: $session_dir"
        return
    fi

    func_count=0
    [[ -d "$func" ]] && func_count=$(find "$func" -maxdepth 1 -type f | wc -l)
    info "functional files: $func_count (42 is the usual complete-session count)"

    if [[ ! -d "$func" ]]; then
        fail "func folder is missing"
        echo "FAIL: func folder is missing"
    else
        while IFS= read -r filename; do
            [[ "$filename" =~ _run-([0-9]+)_ ]] &&
                [[ "${BASH_REMATCH[1]}" != 01 ]] && extra_runs+=("$filename")
        done < <(find "$func" -maxdepth 1 -type f -printf '%f\n' | sort)
        if [[ ${#extra_runs[@]} -gt 0 ]]; then
            warn "additional functional runs found"
            echo "WARN: additional functional runs found"
        fi
    fi

    if [[ -d "$anat" ]]; then
        check_anat "$anat" "$SUBJECT" "$session"
    else
        fail "anat folder is missing"
        echo "FAIL: anat folder is missing"
    fi

    if [[ -d "$func" ]]; then
        for label in bandit circle ghost mdp1 mdp2; do
            check_task "$func" "$SUBJECT" "$session" "$label"
        done
        berry_labels=()
        for label in berry coin; do
            compgen -G "$func/${SUBJECT}_${session}_task-${label}_run-01_*" >/dev/null &&
                berry_labels+=("$label")
        done
        if [[ ${#berry_labels[@]} -eq 0 ]]; then
            fail "func berry/coin: task-berry and task-coin are missing"
            echo "FAIL: func berry/coin not found"
        else
            if [[ ${#berry_labels[@]} -eq 2 ]]; then
                warn "both task-berry and task-coin found"
                echo "WARN: both task-berry and task-coin found"
            fi
            for label in "${berry_labels[@]}"; do
                check_task "$func" "$SUBJECT" "$session" "$label" "berry/coin (task-$label)"
            done
        fi
        while IFS= read -r file; do
            check_identity "$file" "$SUBJECT" "$session"
        done < <(find "$func" -maxdepth 1 -type f -printf '%p\n' | sort)
    fi

    if [[ -d "$fmap" ]]; then
        check_fmap "$fmap" "$SUBJECT" "$session" "$BIDS_ROOT/$SUBJECT"
        while IFS= read -r file; do
            check_identity "$file" "$SUBJECT" "$session"
        done < <(find "$fmap" -maxdepth 1 -type f -printf '%p\n' | sort)
    else
        fail "fmap folder is missing"
        echo "FAIL: fmap folder is missing"
    fi

    check_nm "$BIDS_ROOT/derivatives/$SUBJECT/$session/anat"
}

for session_dir in "${sessions[@]}"; do
    check_session "$session_dir"
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
((failed == 0))
