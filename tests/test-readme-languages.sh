#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

readmes=(
  README.md
  docs/readme/README.ru.md
  docs/readme/README.es.md
  docs/readme/README.de.md
  docs/readme/README.fr.md
  docs/readme/README.pt.md
  docs/readme/README.zh-CN.md
  docs/readme/README.ja.md
  docs/readme/README.ar.md
  docs/readme/README.hi.md
)

[[ "${#readmes[@]}" == 10 ]]
grep -Fqx '# Lightweight Ubuntu Server Setup' README.md

for readme in "${readmes[@]}"; do
  [[ -s "$readme" ]]
  grep -Fq 'https://github.com/ochenstarik-ui/server-monitor-manager' "$readme"
  grep -Fq 'English' "$readme"
  grep -Fq 'Русский' "$readme"
  grep -Fq 'Español' "$readme"
  grep -Fq 'हिन्दी' "$readme"
done

printf 'README language and monitoring links passed.\n'
