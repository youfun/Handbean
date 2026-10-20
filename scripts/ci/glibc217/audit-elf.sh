#!/usr/bin/env bash
set -euo pipefail

release=${1:?release directory is required}
output=${2:?output directory is required}
mkdir -p "$output/details"

summary="$output/elf-summary.tsv"
report="$output/elf-audit.txt"
failures="$output/failures.txt"
: >"$summary"
: >"$report"
: >"$failures"
printf 'path\tmax_glibc\tmax_glibcxx\tmax_cxxabi\tunresolved\trpath_runpath\n' >>"$summary"

version_at_most() {
  local actual=$1
  local maximum=$2
  [[ $(printf '%s\n%s\n' "$actual" "$maximum" | sort -V | tail -1) == "$maximum" ]]
}

count=0
absolute_rpath_count=0
while IFS= read -r -d '' path; do
  if ! readelf -h "$path" >/dev/null 2>&1; then
    continue
  fi

  count=$((count + 1))
  relative=${path#"$release"/}
  safe_name=$(printf '%s' "$relative" | tr '/ ' '__')
  detail="$output/details/${safe_name}.txt"

  file_output=$(file "$path")
  dynamic_output=$(readelf -d "$path" 2>&1 || true)
  ldd_output=$(ldd "$path" 2>&1 || true)
  versions_output=$(readelf --version-info "$path" 2>&1 || true)
  symbols_output=$(objdump -T "$path" 2>&1 | grep -E 'GLIBC(_|XX_)|CXXABI_' || true)

  {
    printf 'PATH: %s\n\n' "$relative"
    printf '== file ==\n%s\n\n' "$file_output"
    printf '== readelf -d ==\n%s\n\n' "$dynamic_output"
    printf '== ldd ==\n%s\n\n' "$ldd_output"
    printf '== readelf --version-info ==\n%s\n\n' "$versions_output"
    printf '== objdump -T versioned symbols ==\n%s\n' "$symbols_output"
  } >"$detail"

  cat "$detail" >>"$report"
  printf '\n%s\n\n' '================================================================================' >>"$report"

  max_glibc=$(printf '%s\n%s\n' "$versions_output" "$symbols_output" |
    grep -oE 'GLIBC_[0-9]+([.][0-9]+)*' | sort -Vu | tail -1 || true)
  max_glibcxx=$(printf '%s\n%s\n' "$versions_output" "$symbols_output" |
    grep -oE 'GLIBCXX_[0-9]+([.][0-9]+)*' | sort -Vu | tail -1 || true)
  max_cxxabi=$(printf '%s\n%s\n' "$versions_output" "$symbols_output" |
    grep -oE 'CXXABI_[0-9]+([.][0-9]+)*' | sort -Vu | tail -1 || true)
  unresolved=$(printf '%s\n' "$ldd_output" |
    awk '$2 == "=>" && $3 == "not" && $4 == "found" {print $1}' | paste -sd, - || true)
  rpath=$(printf '%s\n' "$dynamic_output" |
    awk '/\((RPATH|RUNPATH)\)/ {sub(/^[[:space:]]*/, ""); print}' | paste -sd';' - || true)
  rpath_values=$(printf '%s\n' "$dynamic_output" |
    awk '/\((RPATH|RUNPATH)\)/ && match($0, /\[.*\]/) {print substr($0, RSTART + 1, RLENGTH - 2)}' || true)
  absolute_rpaths=$(printf '%s\n' "$rpath_values" | tr ':' '\n' | awk '/^\// {print}' | paste -sd, - || true)

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$relative" "$max_glibc" "$max_glibcxx" "$max_cxxabi" "$unresolved" "$rpath" >>"$summary"

  if [[ -n "$max_glibc" ]] && ! version_at_most "${max_glibc#GLIBC_}" 2.17; then
    printf '%s requires %s\n' "$relative" "$max_glibc" >>"$failures"
  fi
  if [[ -n "$max_glibcxx" ]] && ! version_at_most "${max_glibcxx#GLIBCXX_}" 3.4.19; then
    printf '%s requires %s (CentOS 7 maximum is GLIBCXX_3.4.19)\n' \
      "$relative" "$max_glibcxx" >>"$failures"
  fi
  if [[ -n "$max_cxxabi" ]] && ! version_at_most "${max_cxxabi#CXXABI_}" 1.3.7; then
    printf '%s requires %s (CentOS 7 maximum is CXXABI_1.3.7)\n' \
      "$relative" "$max_cxxabi" >>"$failures"
  fi
  if [[ -n "$unresolved" ]]; then
    printf '%s has unresolved SONAMEs: %s\n' "$relative" "$unresolved" >>"$failures"
  fi
  if [[ -n "$absolute_rpaths" ]]; then
    absolute_rpath_count=$((absolute_rpath_count + 1))
    printf '%s embeds absolute RUNPATH/RPATH entries: %s\n' \
      "$relative" "$absolute_rpaths" >>"$failures"
  fi
done < <(find "$release" -type f -print0 | sort -z)

{
  printf 'ELF_COUNT=%s\n' "$count"
  printf 'MAX_GLIBC=%s\n' "$(cut -f2 "$summary" | tail -n +2 | grep -E '^GLIBC_[0-9]' | sort -Vu | tail -1 || true)"
  printf 'MAX_GLIBCXX=%s\n' "$(cut -f3 "$summary" | tail -n +2 | grep -E '^GLIBCXX_[0-9]' | sort -Vu | tail -1 || true)"
  printf 'MAX_CXXABI=%s\n' "$(cut -f4 "$summary" | tail -n +2 | grep -E '^CXXABI_[0-9]' | sort -Vu | tail -1 || true)"
  printf 'UNRESOLVED_COUNT=%s\n' "$(cut -f5 "$summary" | tail -n +2 | grep -c . || true)"
  printf 'RPATH_RUNPATH_COUNT=%s\n' "$(cut -f6 "$summary" | tail -n +2 | grep -c . || true)"
  printf 'ABSOLUTE_BUILD_RPATH_COUNT=%s\n' "$absolute_rpath_count"
} | tee "$output/totals.txt"

if [[ $count -eq 0 ]]; then
  echo "release contains no ELF files" >>"$failures"
fi

if [[ -s "$failures" ]]; then
  cat "$failures" >&2
  exit 1
fi
