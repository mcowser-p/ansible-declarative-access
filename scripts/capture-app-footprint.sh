#!/usr/bin/env bash
# capture-app-footprint.sh — install an app in a clean systemd container,
# capture a cairn footprint, and print the evidence needed to write its guide.
#
# Usage:  scripts/capture-app-footprint.sh <package> [el9|el10] [extra pkgs...]
# Env:    CAIRN_SRC=/path/to/cairn   (required)
#         DOCKER_HOST=unix://$HOME/.docker/run/docker.sock  (macOS Docker Desktop)
#
# Leaves artifacts in /tmp/app-guide-<package>/ and the container running
# (named app-guide-<package>) so scripts/verify-app-profile.sh can reuse it.
set -euo pipefail

PKG="${1:?usage: capture-app-footprint.sh <package> [el9|el10] [extra pkgs...]}"
EL="${2:-el9}"
shift || true; shift || true
EXTRA="$*"
IMG="almalinux/9-init"; [ "$EL" = "el10" ] && IMG="almalinux/10-init"
NAME="app-guide-${PKG}"
OUT="/tmp/app-guide-${PKG}"
: "${CAIRN_SRC:?set CAIRN_SRC to the cairn repo path}"
mkdir -p "$OUT"

echo "[*] starting $IMG as $NAME"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --privileged --name "$NAME" \
  -v "${CAIRN_SRC}:/opt/cairn-src:ro" "$IMG" >/dev/null
sleep 5

docker exec -i "$NAME" bash -s -- "$PKG" "$EXTRA" <<'INNER'
set -euo pipefail
PKG="$1"; EXTRA="$2"
dnf install -y -q python3-pip sudo >/dev/null
pip3 -q install /opt/cairn-src pyyaml >/dev/null 2>&1
mkdir -p /etc/cairn /var/lib/cairn
cp /opt/cairn-src/packaging/cairn-footprint-linux.yaml /etc/cairn/footprint.yaml
python3 - <<PY
import yaml
c = yaml.safe_load(open("/etc/cairn/footprint.yaml"))
c.setdefault("exclude", []).extend(["/var/lib/containers/","/var/lib/cairn/","/etc/cairn/"])
yaml.safe_dump(c, open("/etc/cairn/footprint.yaml","w"))
PY
echo "[*] handover baseline"
cairn files init --config /etc/cairn/footprint.yaml >/dev/null
echo "[*] installing $PKG $EXTRA"
dnf install -y -q $PKG $EXTRA >/dev/null
echo "[*] capturing footprint"
cairn footprint --config /etc/cairn/footprint.yaml --app "${PKG%%-*}" \
  --report /root/footprint.json --access-vars /root/access.yml >/dev/null 2>&1 || true
INNER

docker cp "$NAME:/root/footprint.json" "$OUT/footprint-${PKG}.json"
docker cp "$NAME:/root/access.yml" "$OUT/${PKG}-access.yml"

echo
echo "================= RAW GENERATED PROFILE ================="
cat "$OUT/${PKG}-access.yml"
echo
echo "===================== EVIDENCE ========================="
docker exec -i "$NAME" python3 - <<'PY'
import json
m = json.load(open("/root/footprint.json"))
s = m["summary"]
print("SUMMARY:", {k: s.get(k) for k in ("files_added","files_modified","systemd_units","quadlets","users_added","groups_added","membership_changes","executables","risks")})
print("USERS:", [(u["name"], u["uid"], u["shell"]) for u in m["principals"]["users_added"]])
print("GROUPS:", [(g["name"], g["gid"]) for g in m["principals"]["groups_added"]])
print("MEMBERSHIP:", [(c["group"], c["users_added"]) for c in m["principals"]["membership_changes"]])
units = {u["name"]: u for u in m["services"]["systemd_units"]}
for n in sorted(units):
    u = units[n]
    extra = f" activates={u['activates']}" if u["unit_type"] == "timer" else ""
    print(f"UNIT {n}: type={u['unit_type']} user={u.get('user')}{extra}")
for q in m["services"].get("quadlets", []):
    print(f"QUADLET {q['name']}: service={q['service_name']} rootless={q['rootless']}")
print("RISK KINDS:", sorted({r['kind'] for r in m['risks']}))
for r in m["risks"]:
    if r["severity"] in ("high","critical"):
        print(f"  [{r['severity']}] {r['detail']}")
cats = m["filesystem"]["added_by_category"]
for c in ("config","state_dir","log_dir","opt_tree","srv_tree"):
    d = sorted(e["path"] for e in cats.get(c, []) if e["is_dir"])
    if d: print(f"{c.upper()} DIRS:", d[:12])
PY
echo
echo "[*] artifacts in $OUT ; container '$NAME' left running for verify-app-profile.sh"
