#!/usr/bin/env bash
# verify-app-profile.sh — apply a reviewed app profile to a simulated
# restricted group inside the capture container, then prove allow/deny/revoke.
#
# Usage:  scripts/verify-app-profile.sh <package>
# Pre:    scripts/capture-app-footprint.sh <package> ran and left the
#         'app-guide-<package>' container running; you have written
#         examples/<package>-access.yml.
set -euo pipefail

PKG="${1:?usage: verify-app-profile.sh <package>}"
NAME="app-guide-${PKG}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="examples/${PKG}-access.yml"
[ -f "${REPO}/${PROFILE}" ] || { echo "missing ${PROFILE} — write the reviewed profile first"; exit 1; }
docker inspect "$NAME" >/dev/null 2>&1 || { echo "container $NAME not found — run capture-app-footprint.sh first"; exit 1; }

echo "[*] staging repo + tooling into $NAME"
docker cp "$REPO" "$NAME:/opt/linux-access" >/dev/null
docker exec -i "$NAME" bash -s -- "$PKG" <<'INNER'
set -euo pipefail
PKG="$1"
dnf install -y -q ansible-core acl sudo >/dev/null
ansible-galaxy collection install community.general ansible.posix >/dev/null 2>&1
groupadd "${PKG}-team-sim" 2>/dev/null || true
id appdev >/dev/null 2>&1 || useradd -m -G "${PKG}-team-sim" appdev
export ANSIBLE_ROLES_PATH=/opt/linux-access/roles
echo "===== APPLY examples/${PKG}-access.yml to ${PKG}-team-sim ====="
ansible-playbook -i localhost, -c local \
  /opt/linux-access/playbooks/5_apply_access_profile.yml \
  -e @/opt/linux-access/examples/${PKG}-access.yml \
  -e "group_name=${PKG}-team-sim" -e "declarative_access_sudo_nopasswd=true" \
  2>&1 | grep -E "PLAY RECAP" -A1 | tail -1
echo "===== dev's granted verbs ====="
sudo -l -U appdev | tr "," "\n" | grep -oE "systemctl [a-z-]+ [a-zA-Z0-9@.-]+" | sort -u | head -30
echo "===== REVOKE (real --tags cleanup path; the tag selects, the var arms) ====="
ansible-playbook -i localhost, -c local \
  /opt/linux-access/playbooks/5_apply_access_profile.yml \
  -e @/opt/linux-access/examples/${PKG}-access.yml \
  -e "group_name=${PKG}-team-sim" \
  --tags cleanup -e declarative_access_force_cleanup=true --skip-tags login \
  2>&1 | grep -E "PLAY RECAP" -A1 | tail -1
ls /etc/sudoers.d/ | grep -c "${PKG}" >/dev/null 2>&1 && echo "WARN sudoers survived" || echo "OK sudoers file removed"
INNER
echo "[*] verify done. Review the granted verbs above against the guide's 'still yours' list."
