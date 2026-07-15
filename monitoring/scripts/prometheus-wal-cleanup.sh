#!/bin/sh
set -eu

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*"
}

bad_dec="$(printf '%s' "$BAD_SEGMENT" | sed 's/^0*//')"
if [ -z "$bad_dec" ]; then
  bad_dec=0
fi

removed=0
prometheus_data_dir="${PROMETHEUS_DATA_DIR:-/prometheus}"

log "Mounted $prometheus_data_dir. Current usage:"
du -h -d 1 "$prometheus_data_dir" || true
df -h "$prometheus_data_dir"

log "Deleting WAL segment $BAD_SEGMENT and later WAL files."
for path in "$prometheus_data_dir"/wal/[0-9]*; do
  [ -e "$path" ] || continue
  name="${path##*/}"
  value="$(printf '%s' "$name" | sed 's/^0*//')"
  if [ -z "$value" ]; then
    value=0
  fi
  if [ "$value" -ge "$bad_dec" ]; then
    log "Removing WAL segment $name."
    rm -f "$path"
    removed=$((removed + 1))
  fi
done

log "Deleting WAL checkpoints at or after $BAD_SEGMENT, if any."
for path in "$prometheus_data_dir"/wal/checkpoint.*; do
  [ -e "$path" ] || continue
  name="${path##*.}"
  value="$(printf '%s' "$name" | sed 's/^0*//')"
  if [ -z "$value" ]; then
    value=0
  fi
  if [ "$value" -ge "$bad_dec" ]; then
    log "Removing WAL checkpoint ${path##*/}."
    rm -rf "$path"
    removed=$((removed + 1))
  fi
done

if [ "$removed" -eq 0 ]; then
  log "No WAL files or checkpoints matched BAD_SEGMENT=$BAD_SEGMENT."
  exit 1
fi

sync
log "Recovery cleanup removed $removed entries. Final usage:"
du -h -d 1 "$prometheus_data_dir" || true
df -h "$prometheus_data_dir"
