# shellcheck shell=bash disable=SC2034
# fm-unit-install-lib.sh - the one implementation of rendering and installing a
# tracked systemd --user unit template for the arm helpers.
#
# Sourced by bin/fm-capacity-brake-arm.sh, bin/fm-captain-context-watch-arm.sh,
# and bin/fm-self-update-timer-arm.sh. Each caller sources bin/fm-pr-lib.sh
# first for the private-file safety primitives this uses.

# fm_unit_render <template> <placeholder=value>...
# Replace each literal placeholder with its value, in the order given.
fm_unit_render() {
  local template=$1 text pair
  shift
  text=$(cat "$template") || return 1
  for pair in "$@"; do
    text=${text//"${pair%%=*}"/"${pair#*=}"}
  done
  printf '%s\n' "$text"
}

# fm_unit_install <unit-dir> <template> <destination> <placeholder=value>...
# Install the rendered template at the destination by rename. Refuses a symlink
# or a non-regular destination and rewrites only when the rendered bytes differ,
# so a re-arm does not churn the file or force an unnecessary daemon-reload.
# Sets FM_UNIT_CHANGED=yes only when the destination was actually written and
# FM_UNIT_ERROR to the refusal reason on failure.
FM_UNIT_CHANGED=no
FM_UNIT_ERROR=""

fm_unit_install() {
  local unit_dir=$1 template=$2 dest=$3
  shift 3
  local rendered device tmp
  FM_UNIT_CHANGED=no
  FM_UNIT_ERROR=""
  [ -d "$unit_dir" ] && [ ! -L "$unit_dir" ] || mkdir -p "$unit_dir" || return 1
  device=$(fm_pr_file_device "$unit_dir") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$device" \
    || { FM_UNIT_ERROR="refusing symlink or unusable path at $dest"; return 1; }
  rendered=$(fm_unit_render "$template" "$@") || return 1
  if [ -f "$dest" ] && [ ! -L "$dest" ] \
    && [ "$(cat "$dest" 2>/dev/null)" = "$rendered" ]; then
    return 0
  fi
  tmp=$(umask 022; mktemp "$unit_dir/.fm-unit.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$rendered" > "$tmp" \
    || ! chmod 0644 "$tmp" \
    || ! fm_pr_regular_destination_on_device_or_absent "$dest" "$device" \
    || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  FM_UNIT_CHANGED=yes
  return 0
}
