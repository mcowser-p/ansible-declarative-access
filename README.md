# Using declarative_access: A Practical Guide for Linux Systems

This guide explains how to define the administrative access for your Linux application. We will cover creating an application profile. The declarative_access role uses Linux-specific tools and features:
- realm for Active Directory integration
- setfacl for file/folder ACL management
- systemctl for service, timer, and podman-quadlet management
- sudoers for command access control
- pam_group.so for temporary local group membership
- chown/chmod for file and folder ownership
- loginctl lingering for rootless (user-level) systemd services

Using your team's AD group and/or service account, you can specify exactly what access your team needs on each type of Linux server using either pre-built application profiles or custom configurations.

> **Variable naming:** all role variables are prefixed `declarative_access_`
> (Ansible Galaxy standard). Migrating older playbooks? See the mapping table
> in [docs/declarative-systemd-access.md](docs/declarative-systemd-access.md#variable-migration-v1--galaxy-standard-names).
> The repo also builds as the **`mcowser_p.linux_access`** collection
> (`ansible-galaxy collection build`).

## Quick Start: Generated Access Profiles (cairn)

The fastest path for an *application team's* access is to generate the profile
from what their install actually created. cairn captures an install footprint
on a build/staging host and exports a ready-to-review vars file — services,
timers, quadlets, unit files, folders, and ownership:

```bash
# On the build host, after the team installs their app:
sudo cairn footprint --config cairn-footprint-linux.yaml \
  --app myapp --report footprint-myapp.json --access-vars myapp-access.yml

# Review myapp-access.yml (see examples/myapp-access.yml for the shape), then:
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @myapp-access.yml -e "group_name=<hostname>-app_restricted"

# Remove later:
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @myapp-access.yml -e "group_name=<hostname>-app_restricted" --tags cleanup
```

The team ends up able to administer exactly the systemd services, timers, and
quadlets they installed — and the folders that got set up — nothing else.

Grants are removable at every stage: delete `declarative_access_files_modify`
/ `declarative_access_ownership` from the vars file (read-only units, no
chown), neutralize them at apply time with `-e '{"declarative_access_files_modify": []}'`,
or revoke everything already granted — sudoers, group.conf, lingering, **and
the ACLs** — with `--tags cleanup`. (`systemctl edit` is never granted by any
default action set.) Full workflow, diagrams, security tradeoffs, and the
tighten/revoke guide:
[docs/declarative-systemd-access.md](docs/declarative-systemd-access.md).
The full server/AD lifecycle around this — Packer builds, handover baseline,
setup window in app-full, review gate, and the flip to restricted admin — is
in [docs/application-deployment-lifecycle.md](docs/application-deployment-lifecycle.md).
Per-application walkthroughs (install → drop-in setup → admin → before/after
access), starting with Apache httpd, are in
[docs/applications/](docs/applications/README.md).

## Access Separation Architecture

**Key Concept: System Teams vs. Application Teams**

This system separates **system teams access** from **application team access**, allowing us to determine what access a user needs based solely on the server name. This architecture provides:

1. **Clear Access Boundaries**: System administrators get infrastructure access, while application teams get only the access needed for their applications.

2. **Server-Based Access Control**: By looking at the server name (e.g., `ps-zzzapp-tst1`), we can automatically determine which AD groups should have access and what level of access they need.

3. **Nested Group Support**: We can nest AD groups to define hierarchical access for services:
   - `{hostname}-admin_full` contains system administrators
   - `{hostname}-app_full` contains full application administrators
   - `{hostname}-app_restricted` contains restricted application administrators
   - Application-specific groups can be nested within these app groups to grant service-level access

4. **Efficient Group Nesting**:
   - **Key Design**: The `{hostname}-app_full` group is automatically added as a member of `{hostname}-app_restricted`
   - **Benefit**: File permissions (ACLs) only need to be applied to the `app-restricted` group
   - **Result**: Members of `app-full` automatically inherit all file access permissions from `app-restricted`
   - **Simplicity**: This reduces configuration complexity and ensures consistent access patterns

5. **Benefits**:
   - **Auditable**: Clear lineage of who has access through group membership
   - **Scalable**: Easy to add new servers with consistent access patterns
   - **Secure**: Principle of least privilege applied at every level
   - **Manageable**: Access changes are made through AD group membership, not individual server configuration
   - **Efficient**: File permissions applied once to `app-restricted` are inherited by `app-full` members

**Domain Group Naming Standard:**
```
{hostname}-admin_full          System administrators
{hostname}-app_full            Full administrative access over the server
{hostname}-app_restricted      Restricted application access (default)
```

Groups are created by `playbooks/1_create_ad_groups.yml` using the `microsoft.ad.group` module.

**Example Access Hierarchy**:
```
ps-zzzapp-tst1-admin_full              (System administrators)
  └── role.ps.admins

ps-zzzapp-tst1-app_full                (Full administrative access over the server)
  └── role.XX.web-app-admins

ps-zzzapp-tst1-app_restricted          (Limited application access)
  └── ps-zzzapp-tst1-app_full          (Nested - inherits all file permissions!)
  └── role.XX.web-app-dev              (Direct membership)
```

**How It Works:**
When we apply ACLs to `/etc/nginx/` for the `ps-zzzapp-tst1-app_restricted` group:
- Direct members of `ps-zzzapp-tst1-app_restricted` get access
- Members of `ps-zzzapp-tst1-app_full` get access (via group nesting)
- You only configure file permissions once on `app-restricted`

**User Access States:**
The two application groups represent the two states a user's access can be in:
- `{hostname}-app_full` — full administrative access over the server, used during initial setup and application installation
- `{hostname}-app_restricted` — limited to only what the application profile defines, used once the application is installed and configured

This separation ensures that application teams can manage their applications without requiring system-level access, while system administrators can maintain infrastructure without application-specific knowledge.

## Quick Start: Application Profiles

The fastest way to get started is using pre-built application profiles. These provide common access patterns for specific applications:

### Available Application Profiles

**Nginx Web Server Profile (`playbooks/application_profile_examples/nginx-webserver.yml`)**
```bash
# Uses server-specific app-restricted group ({hostname}-app_restricted) by default
ansible-playbook playbooks/application_profile_examples/nginx-webserver.yml -i inventory

# Or specify custom group
ansible-playbook playbooks/application_profile_examples/nginx-webserver.yml -e "group_name=ps-webadmins"

# Cleanup access
ansible-playbook playbooks/application_profile_examples/nginx-webserver.yml --tags cleanup
```

Provides:
- **Default Group**: `{hostname}-app_restricted` (e.g., "ps-zzzapp-tst1-app_restricted")
- Service management: nginx start/stop/restart/reload/status
- Configuration access: /etc/nginx/, /etc/nginx/conf.d/, /etc/nginx/sites-available/, /etc/nginx/sites-enabled/
- Web content: /usr/share/nginx/html/, /var/www/html/ (modify)
- Log access: /var/log/nginx/ (read-only)
- Commands: /usr/sbin/nginx (for config testing)

**TLS/SSL Certificate Profile for Alma Linux (`playbooks/application_profile_examples/tls-alma-linux.yml`)**
```bash
# Uses server-specific app-restricted group ({hostname}-app_restricted) by default
ansible-playbook playbooks/application_profile_examples/tls-alma-linux.yml -i inventory

# Or specify custom group
ansible-playbook playbooks/application_profile_examples/tls-alma-linux.yml -e "group_name=ps-certadmins"

# Cleanup access
ansible-playbook playbooks/application_profile_examples/tls-alma-linux.yml --tags cleanup
```

Provides:
- **Default Group**: `{hostname}-app_restricted` (e.g., "ps-zzzapp-tst1-app_restricted")
- Certificate management commands: openssl, update-ca-trust, c_rehash
- SSL/TLS directory access: /etc/pki/tls/ (modify)
- Certificate storage: /etc/pki/tls/certs/ (modify)
- Private keys: /etc/pki/tls/private/ (modify)
- CA trust anchors: /etc/pki/ca-trust/source/anchors/ (modify)
- Audit logs: /var/log/audit/ (read-only)

**Note on Group Naming Convention:**

The system uses three standard group types per server, created by `playbooks/1_create_ad_groups.yml`:
- `{hostname}-admin_full`: Full administrative access
- `{hostname}-app_full`: Full administrative access over the server
- `{hostname}-app_restricted`: Restricted application access (default for most profiles)

Group names use a dash between hostname and purpose, with underscores inside the purpose (`<hostname>-<purpose>`, e.g. `web01-app_restricted`).

Examples:
- For server "ps-zzzapp-tst1": `ps-zzzapp-tst1-admin_full`, `ps-zzzapp-tst1-app_full`, `ps-zzzapp-tst1-app_restricted`
- For server "ps-zzzapp-tst2": `ps-zzzapp-tst2-admin_full`, `ps-zzzapp-tst2-app_full`, `ps-zzzapp-tst2-app_restricted`

### Using Application Profiles

1. **Basic Usage (Server-Specific Groups)**:
```bash
# Use default server group ({hostname}-app_restricted)
ansible-playbook playbooks/application_profile_examples/tls-alma-linux.yml -i inventory

# This automatically uses the server's restricted app group:
# For server "ps-zzzapp-tst1" -> uses AD group "ps-zzzapp-tst1-app_restricted"
# For server "ps-zzzapp-tst2" -> uses AD group "ps-zzzapp-tst2-app_restricted"
```

2. **Custom Group Usage**:
```bash
# Override with specific AD group
ansible-playbook playbooks/application_profile_examples/tls-alma-linux.yml \
  -e "group_name=ps-certadmins" \
  -i inventory
```

3. **For Individual Users**:
```bash
# Grant user access using TLS profile
ansible-playbook playbooks/application_profile_examples/tls-alma-linux.yml \
  -e "user_name=svc.XX.tls.web.tst" \
  -i inventory
```

4. **Cleanup Access**:
```bash
# Remove access (uses same group logic as above)
ansible-playbook playbooks/application_profile_examples/tls-alma-linux.yml \
  --tags cleanup \
  -i inventory

# Remove access for specific group
ansible-playbook playbooks/application_profile_examples/tls-alma-linux.yml \
  -e "group_name=ps-certadmins" \
  --tags cleanup \
  -i inventory
```

### Creating Custom Application Profiles

You can create your own application profiles by copying and modifying the existing examples:

```yaml
---
- name: Custom Application Profile
  hosts: all
  gather_facts: true
  vars:
    # Use group_name OR user_name, not both
    group_name: "{{ group_name | default('') }}"
    user_name: "{{ user_name | default('') }}"

    # Default to {hostname}-app_restricted
    default_group: "{{ ansible_hostname | lower }}-app_restricted"

  tasks:
    - name: Setup custom application access
      ansible.builtin.include_role:
        name: declarative_access
      vars:
        declarative_access_group: "{{ group_name if group_name else ('' if user_name else default_group) }}"
        declarative_access_user: "{{ user_name if user_name else '' }}"
        declarative_access_login: false
        declarative_access_sudo: true
        declarative_access_profile_name: "custom-app"
        declarative_access_services:
          - "your-service"
        declarative_access_timers:
          - "your-maintenance-timer"      # granted as <name>.timer
        declarative_access_quadlets:
          - "your-container"              # your-container.container → .service
        declarative_access_folders_read:
          - "/var/log/your-app/"
        declarative_access_folders_modify:
          - "/etc/your-app/"
        declarative_access_commands:
          - "/usr/bin/your-command"
```

## Advanced: Custom Access Configurations

## File and Folder Access Patterns

The role provides granular control over file and folder permissions:

### Read Access
```yaml
declarative_access_files_read:
  - "/etc/httpd/conf/httpd.conf"     # Read specific config files
  - "/etc/nginx/nginx.conf"
declarative_access_folders_read:
  - "/var/log/httpd"                 # Read entire log directories
  - "/var/log/nginx"
  - "/var/log/application"           # Application logs
```

### Modify Access
```yaml
declarative_access_files_modify:
  - "/etc/logrotate.d/httpd"         # Modify specific files
  - "/etc/logrotate.d/application"
declarative_access_folders_modify:
  - "/etc/httpd/conf.d"              # Modify config directories
  - "/etc/nginx/conf.d"              # Allow creating/editing configs
  - "/var/www/html"                  # Web content
```

### Execute Access
```yaml
declarative_access_files_exec:
  - "/opt/app/scripts/deploy.sh"     # Execute specific scripts
  - "/usr/local/bin/backup-tool"    # Custom tools
```

### Ownership (user and group owner)
```yaml
declarative_access_ownership:
  - path: "/var/lib/myapp"           # file OR folder
    owner: "myapp"
    group: "myapp"
    mode: "0750"
  - path: "/data/myapp"              # setgid team folder, recursive
    owner: "svc.myapp"
    group: "myapp-restricted"
    mode: "2750"
    recurse: true
```

### Common Access Patterns

1. **Web Server Access**:
```yaml
declarative_access_folders_read:
  - "/var/log/httpd"                 # Web server logs
  - "/var/log/nginx"                 # Nginx logs
  - "/var/log/php-fpm"              # PHP logs
declarative_access_folders_modify:
  - "/etc/httpd/conf.d"             # Apache configs
  - "/etc/nginx/conf.d"             # Nginx configs
  - "/etc/php-fpm.d"               # PHP-FPM configs
  - "/var/www/html"                # Web content
```

2. **Database Access**:
```yaml
declarative_access_folders_read:
  - "/var/log/postgresql"           # Database logs
  - "/var/log/mysql"
declarative_access_folders_modify:
  - "/etc/postgresql/conf.d"        # Database configs
  - "/etc/my.cnf.d"
```

3. **Application Access**:
```yaml
declarative_access_folders_read:
  - "/var/log/application"          # App logs
  - "/opt/application/logs"         # Custom log location
declarative_access_folders_modify:
  - "/opt/application/config"       # App configs
  - "/opt/application/content"      # App content
declarative_access_files_exec:
  - "/opt/application/scripts/deploy.sh"  # Deployment scripts
```

### Security Features

1. **Directory Level Security**:
   - The role automatically skips the first two directory levels when granting traverse permissions
   - For `/var/log/httpd`, you get traverse permissions on `/var/log`, not on `/` or `/var`
   - This prevents granting unnecessary access to root-level directories

2. **Default Permissions**:
   - declarative_access_folders_read: r-x (read + traverse)
   - declarative_access_folders_modify: rwx (full access)
   - declarative_access_files_read: r-- (read only)
   - declarative_access_files_modify: rw- (read + write)
   - declarative_access_files_exec: r-x (read + execute)

3. **Scoped Unit Grants**:
   - Timers are granted as `<name>.timer` explicitly (a bare name would resolve to the `.service`)
   - Quadlet-generated services get lifecycle actions only (start/stop/restart/status) — generator units cannot be enabled/disabled/masked
   - Write ACLs on unit files are root-equivalent for that unit; review generated profiles before applying (see [docs/declarative-systemd-access.md](docs/declarative-systemd-access.md#security-tradeoffs--read-before-applying))

## Using Individual Examples

If you need very specific access patterns, you can use the individual examples in the `playbooks/setting_file_access_examples/` directory:

### Group Examples
```bash
# Grant group read access to specific files
ansible-playbook playbooks/setting_file_access_examples/group/grant-GROUP-file-read-access.yml \
  -e "group_name=ps-webadmins" \
  -e "read_file=/etc/httpd/conf/httpd.conf"

# Grant group modify access to folders
ansible-playbook playbooks/setting_file_access_examples/group/grant-GROUP-folder-write-access.yml \
  -e "group_name=ps-webadmins" \
  -e "write_folder=/var/www/html"
```

### User Examples
```bash
# Grant user read access to specific files
ansible-playbook playbooks/setting_file_access_examples/user/grant-USER-file-read-access.yml \
  -e "user_name=svc.XX.tls.web.tst" \
  -e "read_file=/var/log/httpd/access_log"

# Grant user modify access to folders
ansible-playbook playbooks/setting_file_access_examples/user/grant-USER-folder-write-access.yml \
  -e "user_name=svc.XX.tls.web.tst" \
  -e "write_folder=/opt/app/config"
```

## Testing Your Configuration

### Using Molecule Testing

The role includes comprehensive testing scenarios:

```bash
# Test all features (ACLs, sudo with full command verification, behavioral
# pam_group over a real sshd, cleanup) on AlmaLinux 9/10 and Ubuntu 24.04 LTS
molecule test
```

## Releasing and Publishing

Releases are automated: semantic-release parses conventional commits on
`main`, stamps `galaxy.yml`, builds the collection tarball, and attaches it
to a GitHub release (`.releaserc.js` + `.github/workflows/release.yml`).
Note the release rules ignore commits **without a scope** — squash-merge PRs
with a scoped conventional title (e.g. `feat(role): ...`) to cut a release.

**Publishing to Ansible Galaxy is wired but disabled.** To enable it:

1. Change `license` in `galaxy.yml` to an OSI/SPDX license that
   galaxy.ansible.com accepts — `LicenseRef-Proprietary` is rejected at
   import.
2. Sign in to <https://galaxy.ansible.com> with the `mcowser-p` GitHub
   account (this claims the `mcowser_p` namespace; Galaxy maps the dash to
   an underscore) and create an API token.
3. Add the token as the `GALAXY_API_KEY` repository secret.
4. Uncomment the `publishCmd` in `.releaserc.js` and the `GALAXY_API_KEY`
   env line in `.github/workflows/release.yml`.

The publish step then runs only when a release is actually cut, pushing the
same tarball that the GitHub release carries.

### Manual Testing

1. **Check Server Match**:
```bash
# Test which block will match
ansible-playbook -i inventory playbook.yml --list-hosts
```

2. **Dry Run**:
```bash
# Test without making changes
ansible-playbook -i inventory playbook.yml --check
```

3. **Verbose Output**:
```bash
# See detailed execution
ansible-playbook -i inventory playbook.yml -vv
```

## Best Practices

1. **Start with Application Profiles**:
   - Use pre-built profiles when possible
   - Create custom profiles for reusable services
   - Avoid using individual examples only for one-off access

2. **Naming and Organization**:
   - Use descriptive declarative_access_profile_name values this gives a unique name

3. **Security**:
   - Use read-only access when possible
    - Test with --tags cleanup to verify removal
   - Use specific paths instead of broad directories
   - Always include declarative_access_profile_name for tracking

4. **Testing**:
   - Test both application and cleanup scenarios
   - Validate in non-production first

Remember: Application profiles provide the most maintainable and testable approach for common access patterns, while custom configurations offer flexibility for complex requirements.

## License

[Apache License 2.0](LICENSE)
