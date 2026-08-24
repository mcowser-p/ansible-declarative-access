# ad_join

Join a Linux host to Active Directory and establish the SSSD identity contract
the rest of this collection assumes.

`declarative_access` runs `realm permit` and writes `pam_group` mappings for AD
principals. None of that means anything until a host is joined — and nothing in
this collection did the joining. This role is that missing step 0.

## Scope: establish vs diagnose

This role **establishes**. [`mcowser_p.auth_sleuth`](https://github.com/mcowser-p/auth-sleuth)
**diagnoses**, and deliberately never joins. The split is intentional and this
role does not reimplement any of auth-sleuth's checks:

| Concern | Owner |
|---|---|
| SRV / Global Catalog discovery, DC port reachability, time-skew measurement | auth-sleuth |
| `sssctl domain-status`, sssd.conf permission audit, `simple_allow_groups` coverage | auth-sleuth |
| nsswitch audit, `pam_group.so` presence, authselect-drift correlation, pamtester | auth-sleuth |
| Cache clearing, sssd restart, session termination remediation | auth-sleuth |
| Packages, realm/adcli join, sssd.conf identity keys, krb5, PAM stack, keytab | **ad_join** |

Its own post-check is a binary post-condition — `adcli testjoin` plus one keyed
`getent` — and it points at auth-sleuth for anything more.

It also does not write two files `declarative_access` owns:
`simple_allow_groups` in `sssd.conf` (that is `realm permit`) and
`/etc/security/group.conf` plus the `pam_group.so` line.

## Ordering

**Run this before `2_configure_default_pam_access.yml`.** `authselect
apply-changes` regenerates `/etc/pam.d/sshd` from the profile and silently drops
the `pam_group.so` line that playbook inserts. Settling the PAM stack here means
there is no grant yet to destroy.

```
ad_join  ->  1_create_ad_groups  ->  2_configure_default_pam_access  ->  5_apply_access_profile
```

## Usage

```yaml
- hosts: linux
  become: true
  roles:
    - role: mcowser_p.declarative_access.ad_join
      vars:
        ad_join_domain: example.com
        ad_join_user: svc-join
        ad_join_password: "{{ vault_join_password }}"
        ad_join_computer_ou: "OU=Linux,OU=Servers,DC=example,DC=com"
        ad_join_sshd_password_auth_groups:
          - "{{ ansible_hostname | lower }}-app_restricted"
```

Against a **pre-staged** computer object, with no privileged account on the
client — the host authenticates as itself, and AD rotates the machine password
on first use so the value works exactly once:

```yaml
        ad_join_one_time_password: "{{ otp_from_0_create_ad_computer }}"
```

Leave with `-e ad_join_state=left`; full teardown with `--tags cleanup`.

## Variables

See [`defaults/main.yml`](defaults/main.yml) — every option is commented there.
The ones worth knowing about:

| Variable | Default | Why it matters |
|---|---|---|
| `ad_join_access_provider` | `simple` | **Not** realmd's `ad`. `access_provider = ad` routes logon through GPO evaluation, producing the classic "resolves under `getent`, permission denied at SSH" failure. `simple` with an empty allow list is fail-closed until `realm permit` runs. |
| `ad_join_use_fqns` | `true` | Every consumer already assumes `name@domain` — playbook 2's `getent group <g>@<domain>`, `declarative_access_ad_domain`, auth-sleuth's expected-group suffixing. |
| `ad_join_admin_group` | `sudo` on Debian, else `wheel` | The group `pam_group` maps the admin tiers into. Hardcoding `wheel` is what made playbook 2 hard-fail on Ubuntu. |
| `ad_join_sshd_password_auth_groups` | `[]` | The golden images are CIS-hardened to key-only auth, and an AD user has no key on the host. Without a scoped `Match Group` re-enable they cannot authenticate at all. |
| `ad_join_one_time_password` | `""` | Binds to a pre-staged object without a domain-admin credential. Requires `ad_join_computer_ou`. |

## Notes

- **Idempotence is probed with `adcli testjoin`, not `realm list`.** `realm list`
  reports a join from local config alone, so it says "joined" for a host whose
  keytab no longer matches the directory — exactly what a rebuilt DC leaves
  behind. `adcli testjoin` authenticates with the keytab and fails correctly.
- **`sssd.conf` is edited line-level, never templated.** `realm permit` rewrites
  `simple_allow_groups` in that same file out of band; a full template here would
  fight the role this one exists to support.
- **SSSD caches group membership.** A membership change is not live until
  `sss_cache -E`, an `sssd` restart (`sss_cache -E` does not clear the NSS fast
  memcache under `/var/lib/sss/mc`) and `loginctl terminate-user`.
- **`ldap_group_nesting_level` defaults to 2.** One hop from an ops group into
  `<host>-admin_full` is fine; a deeper chain silently drops the grant with no
  error anywhere.
