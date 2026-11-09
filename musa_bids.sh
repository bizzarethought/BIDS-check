#!/usr/bin/env bash
# Post-heudiconv checks for one MUSA participant or session.
# Required: 2 T1w runs, six 3-echo task runs with events, AP/PA fieldmaps with
# valid IntendedFor. NM derivatives are optional (not every participant had NM).
set -u
shopt -s nullglob

command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 2; }
[[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 BIDS_ROOT SUBJECT [SESSION]" >&2; exit 2; }

root=${1%/}
sub=sub-${2#sub-}
ses=${3:+ses-${3#ses-}}
[[ -d $root/$sub ]] || { echo "FAIL: participant directory not found: $root/$sub"; exit 1; }
if [[ -n $ses ]]; then sessions=("$root/$sub/$ses"); else sessions=("$root/$sub"/ses-*/); fi
((${#sessions[@]})) || { echo "FAIL: no sessions found for $sub"; exit 1; }

passed=0 failures=() warnings=()
ok()   { ((++passed)); }
fail() { failures+=("$*"); echo "FAIL: $*"; }
warn() { warnings+=("$*"); echo "WARN: $*"; }
have() { compgen -G "$1" >/dev/null; }

# group LABEL FILE...: every file must exist; one PASS/FAIL line per group.
group() {
    local label=$1 miss=() f; shift
    for f; do [[ -f $f ]] && ok || miss+=("${f##*/}"); done
    if ((${#miss[@]} == 0)); then echo "PASS: $label"
    elif ((${#miss[@]} == $#)); then fail "$label: all $# files missing"
    else fail "$label: missing ${miss[*]}"; fi
}

# check_intended JSON: IntendedFor must list existing func BOLD files of this
# session. Accepts a string or array, relative or bids:: URI paths.
# Uses $s (the session) from check_session.
check_intended() {
    local name=${1##*/} pre="$s/func/${sub}_${s}_task-" t
    while IFS= read -r t; do
        [[ $t == '!'* ]] && { fail "fmap $name: ${t#!}"; return; }
        t=${t#bids::}; t=${t#"$sub"/}
        [[ $t == "$pre"*_bold.nii.gz ]] || { fail "fmap $name: invalid IntendedFor target '$t'"; return; }
        [[ -f $root/$sub/$t ]] || { fail "fmap $name: IntendedFor target not found: $t"; return; }
    done < <(jq -r 'if type != "object" then "!not a JSON object" else .IntendedFor |
                    if type == "string" then . elif type == "array" and length > 0 then .[] | tostring
                    else "!IntendedFor missing or empty" end end' "$1" 2>/dev/null || echo '!invalid JSON')
    ok
}

check_session() {
    local d=${1%/} s=${1%/}; s=${s##*/}
    local anat=$d/anat func=$d/func fmap=$d/fmap task f n0 bc=() nm
    echo
    echo "Checking $sub/$s"
    echo "--------------------"
    [[ -d $d ]] || { fail "session directory not found: $d"; return; }

    group anat "$anat/${sub}_${s}"_run-0{1,2}_T1w.{nii.gz,json}

    if [[ -d $func ]]; then
        nm=("$func"/*); echo "INFO: func has ${#nm[@]} files (42 expected)"
        for f in "$func"/*_run-*; do
            [[ $f == *_run-01_* ]] || { warn "func: runs other than run-01 found (e.g. ${f##*/})"; break; }
        done
        for task in berry coin; do have "$func/${sub}_${s}_task-${task}_*" && bc+=("$task"); done
        case ${#bc[@]} in
            0) fail "func: neither task-berry nor task-coin found" ;;
            2) warn "func: both task-berry and task-coin found" ;;
        esac
        for task in bandit circle ghost mdp1 mdp2; do
            f=$func/${sub}_${s}_task-${task}_run-01
            group "func $task" "$f"_events.tsv "$f"_echo-{1,2,3}_bold.{nii.gz,json}
        done
        for task in "${bc[@]}"; do
            f=$func/${sub}_${s}_task-${task}_run-01
            group "func berry/coin (task-$task)" "$f"_events.tsv "$f"_echo-{1,2,3}_bold.{nii.gz,json}
        done
    else
        fail "func folder is missing"
    fi

    n0=${#failures[@]}
    for f in AP/nii.gz AP/json PA/nii.gz PA/json; do
        have "$fmap/*_dir-${f%/*}_epi.${f#*/}" && ok || fail "fmap: no dir-${f%/*} .${f#*/} file"
    done
    for f in "$fmap"/*_dir-*_epi.json; do check_intended "$f"; done
    ((${#failures[@]} == n0)) && echo "PASS: fmap (AP/PA present, IntendedFor valid)"

    for f in "$anat"/* "$func"/* "$fmap"/*; do
        [[ ${f##*/} == "${sub}_${s}_"* ]] || fail "name mismatch: ${f##*/} is under $sub/$s"
    done

    nm=("$root/derivatives/$sub/$s/anat"/*_NM.{nii.gz,json})
    if ((${#nm[@]} == 8)); then ok; echo "PASS: NM (8 files)"
    else warn "NM: ${#nm[@]}/8 files; check Pitt scan records/REDCap for whether NM was scanned"; fi
}

for d in "${sessions[@]}"; do check_session "$d"; done

echo
echo "Summary: $passed checks passed, ${#failures[@]} failed, ${#warnings[@]} warnings"
((${#failures[@]})) && echo "Troubleshoot with heudiconv logs, sourcedata DICOMs, REDCap, and Pitt scan records."
((${#failures[@]} == 0))
