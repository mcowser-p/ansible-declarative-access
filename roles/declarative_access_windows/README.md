# declarative_access_windows Role

Ansible role for managing **Windows** application access through Active
Directory groups. The Windows counterpart of
[`declarative_access`](../declarative_access/README.md): same shape (one
opt-in primitive per file, an armed `--tags cleanup` to revoke, the receiving
entity passed at apply time), different substrate.

| Feature | What It Does | Controlled By |
|---------|-------------|---------------|
| **WMSVC** | Remote IIS Manager for non-admins, granted per site | `declarative_access_windows_wmsvc: true` + `_sites` |
| **Delegation** | Which `system.webServer` sections a delegated connection may write | `declarative_access_windows_feature_delegation: true` + `_delegation` |
| **NTFS** | DACL grants with `(OI)(CI)` inheritance, plus pool-identity deny ACEs | `_folders_modify`, `_folders_read`, `_deny_pool_write` |
| **Cert keys** | Read on a certificate's private key — never export | `_cert_keys` |
| **Service SDDL** | `sc.exe sdset` start/stop/query grants | `declarative_access_windows_service_sdset: true` + `_services` |
| **JEA** | Exact-command proxy functions for what nothing above can express | `declarative_access_windows_jea: true` + `_jea_functions` |
| **Local groups** | Standing local group membership | `_local_groups` |
| **Event channels** | Log read access via the Event Log Readers group | `_event_channels` |
| **Ownership** | NTFS owner on files and folders | `_ownership` |

Every variable carries the `declarative_access_windows_` prefix (Ansible
Galaxy / ansible-lint `var-naming[no-role-prefix]` standard).

---

## Table of Contents

- [The honest limits](#the-honest-limits)
- [Quick Start](#quick-start)
- [Role Execution Flow](#role-execution-flow)
- [Variables Reference](#variables-reference)
- [Feature Details](#feature-details)
- [Rollback: why snapshots, not just cleanup](#rollback-why-snapshots-not-just-cleanup)
- [Cleanup / Removing Access](#cleanup--removing-access)
  - [Cleanup is deliberately two-key](#cleanup-is-deliberately-two-key)
- [Differences from the Linux role](#differences-from-the-linux-role)
- [Files and Objects Modified on Target Hosts](#files-and-objects-modified-on-target-hosts)
- [Security Notes](#security-notes)
- [Role Dependencies](#role-dependencies)

---

## The honest limits

**IIS Manager delegation cannot grant application-pool recycle, and it cannot
grant binding or certificate changes.** Both are *server-scope* objects in
IIS's configuration model, not site-scope, so no amount of per-site
delegation reaches them. A delegated site connection also cannot restart
`W3SVC`/`WAS` or run `iisreset`.

That is not a gap in this role — it is the shape of the product. It is
exactly why the `service_sdset` and `jea` primitives exist:

```
what the team needs                  what actually grants it
──────────────────────────────────   ─────────────────────────────────────
edit their site's config features    WMSVC connection + feature delegation
start / stop their own site          WMSVC connection (comes with the site)
write content, read their logs       NTFS (OI)(CI) grants
bind a renewed certificate           JEA  Bind-SiteCert   (server-scope)
recycle their application pool       JEA  Restart-AppPool (server-scope)
restart W3SVC / WAS                  sc.exe sdset         (server-scope)
```

Never granted, at any tenancy: write access to `applicationHost.config` or
`%windir%\system32\inetsrv\config` (root-equivalent for every site on the
host), private-key export, and store-wide certificate rights.

The single-tenant assumption matters for one row: `sc.exe sdset` grants
whole-service control, which is correct when the host belongs to one team and
wrong when it does not. On a shared host, drop `service_sdset` and widen the
JEA endpoint instead — JEA can scope to a site, a service descriptor cannot.

---

## Quick Start

The profile supplies the data; the playbook supplies the entity and decides
which mechanisms to switch on.

```yaml
---
- name: Grant the app team access to their IIS site
  hosts: webservers
  gather_facts: true
  tasks:
    - name: Apply the IIS access profile
      ansible.builtin.import_role:
        name: declarative_access_windows
      vars:
        # --- apply-time decisions (never in a profile) ---
        declarative_access_windows_group: "{{ ansible_hostname | lower }}-app_restricted"
        declarative_access_windows_wmsvc: true
        declarative_access_windows_feature_delegation: true
        declarative_access_windows_service_sdset: true
        declarative_access_windows_jea: true

        # --- from the access profile ---
        declarative_access_windows_profile_name: "iis"
        declarative_access_windows_sites: ["app", "www"]
        declarative_access_windows_app_pools: ["app-pool", "www-pool"]
        declarative_access_windows_services: ["W3SVC", "WAS"]
        declarative_access_windows_delegation:
          read_write:
            - system.webServer/defaultDocument
            - system.webServer/httpErrors
          read_only:
            - system.webServer/handlers
            - system.webServer/modules
        declarative_access_windows_folders_modify:
          - 'C:\inetpub\app'
        declarative_access_windows_folders_read:
          - 'C:\inetpub\logs\LogFiles'
        declarative_access_windows_deny_pool_write:
          - 'C:\inetpub\app\web.config'
        declarative_access_windows_cert_keys:
          - {thumbprint: 'A1B2C3D4E5F60718293A4B5C6D7E8F9012345678', store: 'My'}
        declarative_access_windows_event_channels:
          - System
          - Application
          - Microsoft-Windows-CAPI2/Operational
        declarative_access_windows_jea_functions:
          - Restart-AppPool
          - Bind-SiteCert
        declarative_access_windows_local_groups:
          - IIS_IUSRS
          - Remote Management Users
```

Applying a generated profile is the same call with `-e @<profile>.yml`. Use
your own apply playbook — the Windows analog of
`playbooks/5_apply_access_profile.yml`, importing this role instead of
`declarative_access`:

```bash
ansible-playbook -i inventory <your-apply-playbook>.yml \
  -e @profiles/iis/windows-2022-access.yml \
  -e "declarative_access_windows_group=<hostname>-app_restricted" \
  -e "declarative_access_windows_wmsvc=true" \
  -e "declarative_access_windows_service_sdset=true"
```

> **Every toggle defaults to `false`.** A Windows access profile carries no
> booleans at all — the sibling repo's `tools/check_profiles.py`
> `WINDOWS_ALLOWED` set is data keys only — so an operator must switch each
> mechanism on deliberately. Applying a profile with no toggles set is a
> no-op, which is the safe direction: WMSVC opens an HTTPS listener on
> :8172, `sdset` rewrites a service's security descriptor, and JEA registers
> a remoting endpoint.

---

## Role Execution Flow

```
role: declarative_access_windows
│
├── 0. ENTITY  (entity.yml, included once per run mode)
│   ├── Assert exactly one of _user / _group is set
│   ├── Assert _profile_name is set (it names every rollback artifact)
│   └── Set _entity / _entity_type
│
├── 1. WMSVC                    ── when: _wmsvc == true
│   ├── win_feature Web-Mgmt-Service
│   ├── win_regedit EnableRemoteManagement=1, RequiresWindowsCredentials=1
│   │   └── notify: Restart WMSVC   (both are read at service start)
│   ├── win_service WMSVC auto + started
│   └── ManagementAuthorization::Grant($entity, $site, $false)  per site
│       └── idempotent: enumerate first (API, XML fallback), grant only if absent
│   cleanup → ::Revoke per site
│
├── 2. DELEGATION               ── when: _feature_delegation == true
│   ├── snapshot each section's pre-change OverrideMode (write-once, JSON)
│   ├── _delegation.read_write → OverrideMode = Allow
│   └── _delegation.read_only  → OverrideMode = Deny
│   cleanup → snapshot value, else _delegation_cleanup_mode (Deny)
│
├── 3. NTFS                     ── when: any folder/deny list non-empty
│   ├── SNAPSHOT (Get-Acl).Sddl per path, WRITE-ONCE   ← the real rollback
│   ├── _folders_modify   → Modify,         (OI)(CI)
│   ├── _folders_read     → ReadAndExecute, (OI)(CI)
│   └── _deny_pool_write × _app_pools → DENY Write to IIS AppPool\<pool>
│   cleanup → win_acl state=absent (exact-match removal)
│
├── 4. CERT KEYS                ── when: _cert_keys non-empty
│   ├── resolve by thumbprint or subject in Cert:\LocalMachine\<store>
│   │   (>1 match is an error — renewal leaves same-subject duplicates)
│   └── win_acl on the Cert: path → Read on the private key
│   cleanup → win_acl state=absent
│
├── 5. SERVICE SDDL             ── when: _service_sdset == true
│   ├── SNAPSHOT sc.exe sdshow <svc>, WRITE-ONCE      ← the ONLY rollback
│   └── parse → append allow ACE → sdset (DACL only, SACL untouched)
│   cleanup → restore the snapshot verbatim
│
├── 6. JEA                      ── when: _jea == true
│   ├── assert every _jea_functions name is in the closed catalogue
│   ├── template <module>.psd1, RoleCapabilities\<profile>.psrc, <profile>.pssc
│   │   (_sites / _app_pools baked in as ValidateSet)
│   └── Register-PSSessionConfiguration -NoServiceRestart
│   cleanup → Unregister + remove the .psrc/.pssc
│
├── 7a. LOCAL GROUPS            ── when: _local_groups non-empty
│    └── win_group_membership state=present   (never `pure`)
│    cleanup → state=absent
│
├── 7b. EVENT CHANNELS          ── when: _event_channels non-empty
│    └── membership in Event Log Readers
│    cleanup → remove membership
│
└── 8. OWNERSHIP                ── when: _ownership non-empty
    └── win_owner per {path, owner, recurse}
    NO CLEANUP — ownership is state, not a grant
```

---

## Variables Reference

### Identity (required — set exactly one, non-empty, at apply time)

| Variable | Type | Description |
|----------|------|-------------|
| `declarative_access_windows_group` | string | AD group, e.g. `CONTOSO\myhost-app_restricted` or `myhost-app_restricted` |
| `declarative_access_windows_user` | string | AD user (alternative to the group) |

Both are **forbidden inside a profile** — `tools/check_profiles.py` rejects
them. The profile describes the application; the playbook says who gets it.

### Feature toggles

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `declarative_access_windows_wmsvc` | bool | `false` | Install/enable WMSVC and grant per-site IIS Manager connections |
| `declarative_access_windows_feature_delegation` | bool | `false` | Set section `OverrideMode` per `_delegation` |
| `declarative_access_windows_service_sdset` | bool | `false` | Append service-control ACEs via `sc.exe sdset` |
| `declarative_access_windows_jea` | bool | `false` | Template and register the JEA endpoint |
| `declarative_access_windows_debug` | bool | `false` | Print extra detail during execution |
| `declarative_access_windows_force_cleanup` | bool | `false` | The second key for `--tags cleanup`: the tag selects the cleanup halves, this arms them. Pass with `-e`; never persist in inventory. |

> **Cleanup** is two-key: `--tags cleanup` selects it and `-e declarative_access_windows_force_cleanup=true` arms it — either alone does nothing. See [Cleanup / Removing Access](#cleanup--removing-access).

### Profile-supplied data

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `declarative_access_windows_profile_name` | string | `""` _(required)_ | Names every rollback artifact (SDDL snapshots, JEA capability and endpoint). Asserted non-empty. |
| `declarative_access_windows_sites` | list | `[]` | IIS site names — WMSVC grant scope and the site `ValidateSet` for JEA |
| `declarative_access_windows_app_pools` | list | `[]` | Pool names — the pool `ValidateSet` for JEA and the `IIS AppPool\<pool>` deny identities |
| `declarative_access_windows_services` | list | `[]` | Services to grant control over, e.g. `[W3SVC, WAS]` |
| `declarative_access_windows_delegation` | dict | `{}` | `{read_write: [...], read_only: [...]}` of `system.webServer/*` section paths |
| `declarative_access_windows_folders_modify` | list | `[]` | Folders granted `Modify` with `(OI)(CI)` |
| `declarative_access_windows_folders_read` | list | `[]` | Folders granted `ReadAndExecute` with `(OI)(CI)` |
| `declarative_access_windows_deny_pool_write` | list | `[]` | Paths the pool identities are **denied** `Write` on |
| `declarative_access_windows_cert_keys` | list | `[]` | `[{thumbprint\|subject, store}]` — Read on the private key |
| `declarative_access_windows_event_channels` | list | `[]` | Channels the grant is for; non-empty ⇒ Event Log Readers membership |
| `declarative_access_windows_jea_functions` | list | `[]` | Proxy functions to expose (must be in the catalogue) |
| `declarative_access_windows_local_groups` | list | `[]` | Local groups the entity is placed into |
| `declarative_access_windows_ownership` | list | `[]` | `[{path, owner, recurse}]` — `recurse` optional, default `false` |

### Rights and rollback tuning

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `declarative_access_windows_snapshot_dir` | string | `C:\bootstrap\dap-snapshots` | Where the SDDL snapshots live |
| `declarative_access_windows_rights_folder_modify` | string | `Modify` | Rights applied to `_folders_modify` |
| `declarative_access_windows_rights_folder_read` | string | `ReadAndExecute` | Rights applied to `_folders_read` |
| `declarative_access_windows_rights_pool_deny` | string | `Write` | Rights denied to the pool identity |
| `declarative_access_windows_rights_cert_key` | string | `Read` | Rights on the certificate private key |
| `declarative_access_windows_acl_inherit` | string | `ContainerInherit, ObjectInherit` | The `(OI)(CI)` flags |
| `declarative_access_windows_acl_propagation` | string | `None` | Propagation flags |
| `declarative_access_windows_service_rights` | list | 7 verbs | Service access mask names — see below |
| `declarative_access_windows_delegation_cleanup_mode` | string | `Deny` | `OverrideMode` used at cleanup when a section has no snapshot value |

Cleanup uses the same rights variables as apply, because `win_acl` removes an
ACE by **exact match**. Change a rights value between apply and cleanup and
the cleanup removes nothing.

### WMSVC / event / JEA plumbing

| Variable | Type | Default |
|----------|------|---------|
| `declarative_access_windows_wmsvc_service` | string | `WMSVC` |
| `declarative_access_windows_wmsvc_registry_path` | string | `HKLM:\SOFTWARE\Microsoft\WebManagement\Server` |
| `declarative_access_windows_event_log_readers_group` | string | `Event Log Readers` |
| `declarative_access_windows_jea_module_name` | string | `DeclarativeAccessJEA` |
| `declarative_access_windows_jea_endpoint_name` | string | `""` (⇒ the profile name) |
| `declarative_access_windows_jea_transcript_dir` | string | `C:\bootstrap\dap-jea-transcripts` |
| `declarative_access_windows_jea_restart_winrm` | bool | `false` |

`vars/main.yml` additionally holds the JEA function catalogue and the module
root. Those are role facts, not operator choices — overriding them breaks the
role's own invariants.

---

## Feature Details

### 1. WMSVC — the vendor-native delegation path

Four things must line up before a non-admin can connect IIS Manager:

1. the `Web-Mgmt-Service` feature is installed,
2. `EnableRemoteManagement = 1` (WMSVC refuses remote connections otherwise),
3. `RequiresWindowsCredentials = 1` — forces Windows identities and disables
   IIS Manager's own user database, which would otherwise be a second,
   unmanaged credential store on the host,
4. the entity holds a connection grant **per site**.

Step 4 is the delegation, and it is per site by design: a grant on `app` gives
no visibility of `www`. Both registry values are read at service start, so a
change notifies the `Restart WMSVC` handler.

Idempotency: existing grants are enumerated with
`ManagementAuthorization::GetAuthorizedUsers` before granting, falling back to
reading `administration.config` (the file the API writes) if that overload is
not available on the host's IIS build. Either way the check is against real
state, so `changed` is accurate.

### 2. Feature delegation

A section's `OverrideMode` in `applicationHost.config` decides whether a
site's own `web.config` — and therefore its IIS Manager connection — may set
that section. `read_write` ⇒ `Allow`, `read_only` ⇒ `Deny`; sections in
neither list are untouched.

The mechanism is `Microsoft.Web.Administration` (shipped with IIS, no
PowerShell module needed) rather than `appcmd unlock config`. Same effect,
but the current value can be read first, so `changed` is accurate and the
pre-change value is snapshotted. The CLI equivalents, for the record:

```powershell
appcmd unlock config -section:<section>   # -> Allow
appcmd lock   config -section:<section>   # -> Deny
```

### 3. NTFS

`(OI)(CI)` — `ContainerInherit` + `ObjectInherit` — is the Windows analog of
a POSIX default ACL: content created under the folder inherits the grant, so
a team that deploys new files does not have to re-run the role. It is cleaner
than the POSIX version, which needs a separate default-ACL pass.

The deny ACEs implement the config→ACL doctrine: the worker process must not
be able to rewrite the configuration that decides what the worker process
executes. Denying `IIS AppPool\<pool>` `Write` on `web.config` removes the
most common web-shell persistence path and costs nothing — a healthy site
never writes its own `web.config`. Deny is applied as the product of
`_deny_pool_write × _app_pools`: a deny for a pool that never touches the
path is harmless, and the profile deliberately does not carry the
site→pool→path mapping that would be needed to be cleverer.

Resolving `IIS AppPool\<pool>` to a SID needs the `WebAdministration` module,
so the role ensures the `Web-Scripting-Tools` feature when the deny list is
non-empty.

### 4. Certificate private keys

Read on the key is what a certificate **bind** requires. Export is a
different right and this role never grants it —
`declarative_access_windows_rights_cert_key` is `Read`, and `FullControl` is
not offered as a default because `FullControl` on a key ACL is what lets a
principal re-mark a non-exportable key exportable.

The grant goes through `win_acl`'s `Cert:` provider support rather than
hand-editing the key file's NTFS ACL. That is deliberate: the module acquires
the key with `CryptAcquireCertificatePrivateKey` and sets the descriptor
through `NCryptSetProperty` (CNG) or `CryptSetProvParam` (CAPI), whichever
provider the key actually uses. Editing the file DACL is correct for CAPI
(`%ProgramData%\Microsoft\Crypto\RSA\MachineKeys\…`) and only half right for
CNG, where the security descriptor is a key property rather than just a file
permission. The resolver still reports the key file path — that is what you
inspect when a bind fails:

```
CNG   %ProgramData%\Microsoft\Crypto\Keys\<UniqueName>
CAPI  %ProgramData%\Microsoft\Crypto\RSA\MachineKeys\<UniqueKeyContainerName>
```

A `subject:` selector that matches more than one certificate is an error, not
a guess — renewal leaves the previous certificate in the store with the same
subject.

### 5. Service SDDL

`declarative_access_windows_service_rights` names bits from `winsvc.h`:

| Name | Bit | SDDL | Meaning |
|------|-----|------|---------|
| `QueryConfig` | `0x0001` | `CC` | read the service configuration |
| `ChangeConfig` | `0x0002` | `DC` | **not granted** — rewrites `ImagePath`, root-equivalent |
| `QueryStatus` | `0x0004` | `LC` | read running state |
| `EnumerateDependents` | `0x0008` | `SW` | list dependent services |
| `Start` | `0x0010` | `RP` | start |
| `Stop` | `0x0020` | `WP` | stop |
| `PauseContinue` | `0x0040` | `DT` | not granted by default |
| `Interrogate` | `0x0080` | `LO` | ask the service for current status |
| `UserDefinedControl` | `0x0100` | `CR` | not granted by default |
| `ReadControl` | `0x20000` | `RC` | read the descriptor itself |

The descriptor is parsed with `CommonSecurityDescriptor`, the allow ACE is
**added** to the existing DACL, and the result is re-emitted with
`AccessControlSections::Access` — DACL only, SACL untouched. Writing a SACL
through `sdset` needs `SeSecurityPrivilege` enabled in the token, and there
is no reason to risk that failure mode. Composing a descriptor from scratch
is how services end up with SYSTEM locked out of them; this role never does.

### 6. JEA

Three files make an endpoint:

```
C:\Program Files\WindowsPowerShell\Modules\DeclarativeAccessJEA\
├── DeclarativeAccessJEA.psd1              carrier module (JEA walks PSModulePath)
├── RoleCapabilities\<profile>.psrc        the closed function catalogue
└── <profile>.pssc                         RestrictedRemoteServer + virtual account
```

The session is `RestrictedRemoteServer` (NoLanguage mode) with
`RunAsVirtualAccount = $true`, so the caller never holds admin rights and
cannot construct an argument a `ValidateSet` would reject. `_sites` and
`_app_pools` are baked into those ValidateSets at template time. Every
command is transcribed to
`declarative_access_windows_jea_transcript_dir`.

The catalogue is **closed**: `Restart-AppPool`, `Start-AppPool`,
`Stop-AppPool`, `Get-AppPoolStatus`, `Start-Site`, `Stop-Site`,
`Restart-Site`, `Get-SiteStatus`, `Bind-SiteCert`. A profile naming anything
else fails the play, rather than registering an endpoint that silently
exposes nothing. Adding a function means editing both
`templates/jea_role_capability.psrc.j2` and the catalogue in
`vars/main.yml` — deliberately, because a new proxy function is a new grant.

> **WinRM restart.** `Register-PSSessionConfiguration` restarts the WinRM
> service, which drops the connection when Ansible itself is connected over
> WinRM. The role registers with `-NoServiceRestart`, so the endpoint goes
> live at the next WinRM restart or reboot. Set
> `declarative_access_windows_jea_restart_winrm=true` only when connected
> over SSH.

### 7. Local groups and event channels

Windows builds an access token at logon and never revisits it, so local group
membership is **standing**, not session-scoped — there is no `pam_group`
analog. Granting appears at the entity's next logon; **revoking needs a
forced logoff**:

```
quser                    # find the session
logoff <id>              # terminate it
klist purge -li 0x3e7    # drop cached tickets
```

`_event_channels` records *which* channels the grant is for; the mechanism
granted is membership in the builtin **Event Log Readers** group, which is
broader. Per-channel `wevtutil sl <channel> /ca:<sddl>` is the finer-grained
alternative and is **not** used by default because:

1. `/ca:` **replaces** the channel SDDL rather than merging into it — the same
   hazard as an NTFS DACL replace, with no comparable snapshot story;
2. channel ACLs live in the channel's registry configuration and a servicing
   update that re-creates the channel silently drops them — a grant that
   evaporates on patch Tuesday is worse than a coarse one that does not;
3. some channels (Security in particular) do not accept a channel-level ACL
   change at all;
4. Event Log Readers is what Microsoft ships for this, it is one reversible
   group membership, and on a single-tenant host "can read the logs" is the
   intended grant.

If a host genuinely needs per-channel scoping, do it deliberately outside
this role and capture `wevtutil gl <channel>` first.

### 8. Ownership

`win_owner` per `{path, owner, recurse}`. Ownership matters on Windows beyond
bookkeeping: the owner always holds `WRITE_DAC` implicitly, so an owner can
re-grant itself any access regardless of the DACL. Assigning ownership is a
stronger act than adding an ACE, and a profile should name few paths.

**No cleanup, by design** — matching the Linux role. Ownership is applied
state, not a grant; the previous owner is not recorded, so "undo" has no
defined meaning. Revert deliberately:

```
icacls C:\path /setowner "<previous owner>" /T
```

(For any path that also appears in a folder grant list, the pre-change owner
*is* recoverable: the NTFS SDDL snapshot captures the `O:` field.)

---

## Rollback: why snapshots, not just cleanup

The Linux role can revoke everything with `--tags cleanup` because POSIX ACLs
and sudoers files are additive and separable — removing an entry restores the
prior state exactly. Two Windows mechanisms are not like that, so this role
writes a **write-once snapshot before the first change** and treats it as the
real rollback.

| Object | Why cleanup alone is not enough | Snapshot |
|--------|--------------------------------|----------|
| **NTFS DACL** | `win_acl` itself merges, but cleanup removes ACEs by **exact match** — an ACE widened by hand afterwards survives. And everything *else* that touches DACLs replaces rather than merges: `icacls /grant:r`, `Set-Acl` with a fresh descriptor, "Replace all child object permission entries". | `<snapshot_dir>\<profile>-<sanitized-path>.sddl` |
| **Service descriptor** | `sc.exe` has no "remove one ACE" verb at all. `sdset` takes a complete descriptor and replaces the one on the service. There is no `--tags cleanup` analog. | `<snapshot_dir>\<svc>.sddl` |
| **Section OverrideMode** | The shipped default is *not* uniformly `Deny` — `defaultDocument` and `directoryBrowse` ship `Allow`. Blind-resetting to `Deny` leaves the host tighter than the vendor shipped it. | `<snapshot_dir>\<profile>-delegation.json` |

**Write-once is the whole point.** A second run must never overwrite a
pristine descriptor with the already-granted one, or the undo is destroyed.
Every snapshot task checks for the file before writing.

Restoring an NTFS path by hand:

```powershell
$sddl = Get-Content 'C:\bootstrap\dap-snapshots\iis-C__inetpub_app.sddl' -Raw
$acl  = Get-Acl 'C:\inetpub\app'
$acl.SetSecurityDescriptorSddlForm($sddl)
Set-Acl 'C:\inetpub\app' $acl
```

Snapshots are **never deleted by cleanup**. They are the only record of the
pre-grant state and cost a few hundred bytes each.

---

## Cleanup / Removing Access

Cleanup takes two keys: `--tags cleanup` **selects** the cleanup halves and
`-e declarative_access_windows_force_cleanup=true` **arms** them. During a
normal run, cleanup never happens; with both keys, **only** cleanup tasks
run. With the tag but not the variable, the cleanup tasks print a refusal
and revoke nothing — see
[Cleanup is deliberately two-key](#cleanup-is-deliberately-two-key).

```bash
ansible-playbook -i inventory <your-apply-playbook>.yml \
  -e @profiles/iis/windows-2022-access.yml \
  -e "declarative_access_windows_group=<hostname>-app_restricted" \
  --tags cleanup -e declarative_access_windows_force_cleanup=true
```

Re-run the **same** playbook / vars file: the cleanup halves need the same
entity, the same profile name, the same grant lists, and the same rights
variables.

| Feature | What cleanup does |
|---------|-------------------|
| WMSVC | `ManagementAuthorization::Revoke` per site. The feature, registry values and service are **left in place** — they are host posture shared by every profile. |
| Delegation | Restores each section's snapshotted `OverrideMode`, falling back to `Deny`. |
| NTFS | `win_acl state=absent` for each ACE it added, exact match. Paths that no longer exist are skipped. **This is "remove what I added", not "put it back"** — see the snapshot table. |
| Cert keys | Re-resolves the certificates and removes the Read ACE. Certificates no longer in the store are reported, not silently skipped. |
| Service SDDL | **Restores the snapshot verbatim.** Reverts any DACL change since the snapshot, not just this profile's ACE. With no snapshot, the service is reported and left alone. |
| JEA | `Unregister-PSSessionConfiguration` + removes this profile's `.psrc`/`.pssc`. The carrier module dir and the transcripts stay. |
| Local groups | Removes the entity from each listed group. **Open sessions keep their token** until forced off. |
| Event channels | Removes the entity from Event Log Readers. **Host-wide, not per-profile** — if another profile relies on that membership, re-apply it. (Same caveat as `linger` cleanup on Linux.) |
| Ownership | _(no cleanup)_ — ownership is state, not a grant. |

### Cleanup is deliberately two-key

`--tags cleanup` **selects** the cleanup halves;
`-e declarative_access_windows_force_cleanup=true` **arms** them. Either
alone does nothing: without the tag, `never` keeps the tasks out of every
normal run; without the variable, they print a refusal and touch nothing —
recap green, grants intact.

The variable exists because tags alone are not a guard. Ansible runs a
`never`-tagged task whenever **any of its other tags** is requested, and a
play-level `tags:` is inherited by every task the play executes. A consumer
play carrying its own `tags: [access]`, run with `--tags access`, would
execute the cleanup halves as its own final tasks — JEA endpoint
unregistered, WMSVC grants revoked, group memberships removed, green recap —
right after the apply halves granted them. This exact inheritance tore down
freshly joined hosts through the sibling `ad_join` role before its second
key existed. Nor does moving the tag around offer an escape:

| Wrapper | Result |
|---|---|
| `tags:` on the play | Inherited by the cleanup tasks — trap armed |
| `tags:` on `import_role` / `import_playbook` | Static imports inherit the same way — trap armed |
| `tags:` on `include_role` | Applies only to the include; the role's untagged tasks are filtered out — nothing runs |
| `include_role` with `apply: {tags: [...]}` | Pushes the tag onto the cleanup tasks — trap armed |

If you need stages, prefer separate playbooks (or a variable gate) over tags
around this collection. And keep `declarative_access_windows_force_cleanup`
out of inventory: persisted there, it hands the trigger back to tag
inheritance. It is a command-line key for the one run that revokes.

---

## Differences from the Linux role

| | `declarative_access` | `declarative_access_windows` |
|---|---|---|
| Entity source | apply-time `_user` / `_group` | same |
| Toggles in the profile | yes (`declarative_access_sudo: true`, …) | **no** — profiles are data-only, toggles are apply-time |
| Group membership | session-scoped via `pam_group.so` | **standing**; revocation needs a forced logoff |
| ACL semantics | additive, `setfacl -x` removes cleanly | merge on apply, exact-match on remove; snapshot for the catastrophic case |
| Service verbs | sudoers `systemctl <verb> <unit>` | `sc.exe sdset` access mask |
| Per-command scoping | sudoers command list | JEA proxy functions |
| Log access | `journalctl -u <unit>` via sudoers | Event Log Readers group |
| Rollback | `--tags cleanup` is complete | `--tags cleanup` **plus** SDDL snapshots |
| N/A | — | `linger`, `quadlets` (services are machine-scoped) |

---

## Files and Objects Modified on Target Hosts

| Object | Modified By | Purpose |
|--------|-------------|---------|
| `%windir%\system32\inetsrv\config\administration.config` | WMSVC | per-site IIS Manager connection grants |
| `HKLM:\SOFTWARE\Microsoft\WebManagement\Server` | WMSVC | `EnableRemoteManagement`, `RequiresWindowsCredentials` |
| `WMSVC` service | WMSVC | start mode + running state |
| `%windir%\system32\inetsrv\config\applicationHost.config` | Delegation | section `OverrideMode` |
| Various files/dirs | NTFS, Ownership | DACLs and owner |
| Certificate private keys | Cert keys | key security descriptor (Read) |
| Service security descriptors | Service SDDL | appended allow ACE |
| `C:\Program Files\WindowsPowerShell\Modules\DeclarativeAccessJEA\` | JEA | module, role capability, session config |
| WinRM session configurations | JEA | the registered endpoint |
| Local groups | Local groups, Event channels | membership |
| `C:\bootstrap\dap-snapshots\` | NTFS, Service SDDL, Delegation | the rollback artifacts |
| `C:\bootstrap\dap-jea-transcripts\` | JEA | session transcripts |

---

## Security Notes

1. **Never delegate `applicationHost.config` or `inetsrv\config`** — write
   access there is root-equivalent for every site on the host. The role does
   not offer a way to grant it.
2. **Read on a private key, never export.** `FullControl` on a key ACL lets a
   principal re-mark a non-exportable key exportable.
3. **`ChangeConfig` (`DC`) is not in the default service rights.** Rewriting
   a service's `ImagePath` plus a granted `Start` executes arbitrary code as
   the service account.
4. **`sc.exe sdset` grants whole-service control.** Correct on a
   single-tenant host, wrong on a shared one — drop the primitive and widen
   the JEA endpoint instead.
5. **JEA runs as a virtual account with local admin rights.** That is the JEA
   model: the constraint is the closed function catalogue and the
   ValidateSets, not the run-as token. Review a new proxy function as you
   would a new sudoers line.
6. **Group membership is standing.** The flip is not complete until the
   entity is logged off (`quser` / `logoff` / `klist purge`).
7. **Write access to content plus a pool recycle is close to arbitrary code**
   for classic-ASP/PHP-style sites. The deny-pool-write ACEs narrow the
   persistence path; they do not make content-write safe by itself.
8. **Snapshots are the undo.** Do not delete `C:\bootstrap\dap-snapshots`,
   and do not let a re-run overwrite it (the role will not).
9. **The Windows and POSIX contracts are separate namespaces on purpose.**
   `check_profiles.py` rejects a `declarative_access_*` key in a Windows
   profile and vice versa — applying the wrong one must be impossible by
   construction, not by convention.

---

## Role Dependencies

- `ansible.windows` `>= 2.2.0` — `win_acl` (including its `Cert:`
  private-key support, added in 2.2.0), `win_feature`, `win_regedit`,
  `win_service`, `win_powershell`, `win_group_membership`, `win_owner`,
  `win_file`, `win_stat`, `win_template`.

`community.windows` is **not** required: the role grants on IIS objects, it
never creates them, so it needs nothing from that collection.

## Platform Support

- Windows Server 2022 and 2025 (the IIS delegation surface is unchanged
  between them).
- IIS with `Web-Server`; `Web-Mgmt-Service` for the WMSVC primitive;
  `Web-Scripting-Tools` when `_deny_pool_write` is used (the role installs
  it).
- PowerShell 5.1 for the JEA endpoint.
