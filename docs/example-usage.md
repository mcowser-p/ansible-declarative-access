# Declarative Access Usage Examples

This guide provides practical examples of using the declarative_access system for managing Linux server access.

## Access Architecture Overview

The system separates **system teams** from **application teams** using a three-tier group structure:

- `{hostname}-admin_full`: System administrators (full infrastructure access)
- `{hostname}-app_full`: Full administrative access over the server
- `{hostname}-app_restricted`: Restricted application access (default for most operations)

**Key Efficiency**: `{hostname}-app_full` is automatically a member of `{hostname}-app_restricted`, so file permissions only need to be applied to `app-restricted` and are inherited by `app-full` members.

## Quick Start: Application Profiles

### 1. Nginx Web Server Access

**Grant access using default server group:**
```bash
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml
```

This automatically uses the server's `{hostname}-app_restricted` group.

**Grant access using custom group:**
```bash
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml \
  -e "group_name=ps-webadmins"
```

**What it provides:**
- nginx service management (start/stop/restart/reload/status)
- Configuration access: /etc/nginx/, /etc/nginx/conf.d/
- Web content: /usr/share/nginx/html/, /var/www/html/
- Log access: /var/log/nginx/ (read-only)

### 2. TLS/SSL Certificate Management (Alma Linux)

**Grant certificate administration access:**
```bash
ansible-playbook -i inventory playbooks/application_profile_examples/tls-alma-linux.yml \
  -e "group_name=ps-certadmins"
```

**What it provides:**
- Commands: openssl, update-ca-trust, c_rehash
- SSL directories: /etc/pki/tls/, /etc/pki/tls/certs/, /etc/pki/tls/private/
- CA trust: /etc/pki/ca-trust/source/anchors/
- Audit logs: /var/log/audit/ (read-only)

### 3. Cleanup Access

Cleanup is triggered by adding `--tags cleanup` to the playbook command. When applied, only cleanup tasks run -- no access is granted.

**Remove all access for the default group:**
```bash
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml \
  --tags cleanup
```

**Remove access for a specific group:**
```bash
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml \
  -e "group_name=ps-webadmins" \
  --tags cleanup
```

## Setting File Access Examples

> For a comprehensive guide on using these playbooks -- including service account examples, expected `getfacl` output, and verification steps -- see [Setting File Access](setting-file-access.md).

### Group Access

**Grant folder read access using default group:**
```bash
# Uses {hostname}-app_restricted by default
ansible-playbook -i inventory playbooks/setting_file_access_examples/group/grant-GROUP-folder-read-access.yml \
  -e "read_folder=/var/log/httpd"
```

**Grant folder read access with custom group:**
```bash
ansible-playbook -i inventory playbooks/setting_file_access_examples/group/grant-GROUP-folder-read-access.yml \
  -e "group_name=dev-team" \
  -e "read_folder=/var/log/nginx"
```

**Grant folder write access:**
```bash
ansible-playbook -i inventory playbooks/setting_file_access_examples/group/grant-GROUP-folder-write-access.yml \
  -e "group_name=ops-team" \
  -e "write_folder=/etc/nginx/conf.d"
```

**Grant file read access:**
```bash
ansible-playbook -i inventory playbooks/setting_file_access_examples/group/grant-GROUP-file-read-access.yml \
  -e "group_name=dev-team" \
  -e "read_file=/etc/nginx/nginx.conf"
```

**Grant file modify access:**
```bash
ansible-playbook -i inventory playbooks/setting_file_access_examples/group/grant-GROUP-file-modify-access.yml \
  -e "group_name=ops-team" \
  -e "modify_file=/etc/nginx/nginx.conf"
```

### Individual User Access

**Grant folder read access:**
```bash
ansible-playbook -i inventory playbooks/setting_file_access_examples/user/grant-USER-folder-read-access.yml \
  -e "user_name=svc.XX.nginx.web.prd" \
  -e "read_folder=/var/log/nginx"
```

**Grant folder write access:**
```bash
ansible-playbook -i inventory playbooks/setting_file_access_examples/user/grant-USER-folder-write-access.yml \
  -e "user_name=svc.XX.nginx.deploy.prd" \
  -e "write_folder=/var/www/html"
```

**Grant file read access:**
```bash
ansible-playbook -i inventory playbooks/setting_file_access_examples/user/grant-USER-file-read-access.yml \
  -e "user_name=svc.XX.myapp.monitor.prd" \
  -e "read_file=/etc/nginx/nginx.conf"
```

**Grant file modify access:**
```bash
ansible-playbook -i inventory playbooks/setting_file_access_examples/user/grant-USER-file-modify-access.yml \
  -e "user_name=svc.XX.myapp.config.prd" \
  -e "modify_file=/etc/nginx/conf.d/custom.conf"
```

## Creating AD Groups

**Create server-specific AD groups:**
```bash
ansible-playbook -i localhost, playbooks/1_create_ad_groups.yml \
  -e "hostname=ps-zzzapp-tst1" \
  -e "ad_ou_path=OU=Groups,OU=Servers,DC=example,DC=com" \
  -e "server_admins=role.ps.admins"
```

**This creates:**
- `ps-zzzapp-tst1-admin_full` (contains role.ps.admins)
- `ps-zzzapp-tst1-app_full`
- `ps-zzzapp-tst1-app_restricted` (contains ps-zzzapp-tst1-app_full as member)

## Advanced Usage

### Target Specific Servers

```bash
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml \
  -l "ps-zzzapp-tst1"
```

### Run in Check Mode (Dry Run)

```bash
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml \
  -e "group_name=ps-webadmins" \
  --check
```

### Verbose Output

```bash
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml \
  -e "group_name=ps-webadmins" \
  -vv
```

### Run Specific Tags

```bash
# Only configure ACLs, skip sudo setup
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml \
  -e "group_name=ps-webadmins" \
  --tags setfacl
```

## Understanding Group Nesting

When you apply file permissions to `ps-zzzapp-tst1-app_restricted`:

```
ps-zzzapp-tst1-app_restricted
  └── ps-zzzapp-tst1-app_full (nested member)
      └── role.XX.web-app-admins (direct member)
  └── role.XX.web-app-dev (direct member)
```

**Result:**
- Members of `role.XX.web-app-admins` get access (via app-full -> app-restricted)
- Members of `role.XX.web-app-dev` get access (direct membership)
- You only configured file permissions once on `app-restricted`

## Best Practices

1. **Use Application Profiles First**: Start with pre-built profiles before custom configurations
2. **Default Groups**: Let profiles use the default `{hostname}-app_restricted` group when possible
3. **Test First**: Always run with `--check` before applying to production
4. **Cleanup**: Test cleanup mode to ensure permissions can be fully removed
5. **Service Accounts**: Use service accounts (e.g., `svc.XX.nginx.web.prd`) for automated processes
6. **Monitor**: Review access regularly through AD group membership

## Troubleshooting

### Check Current ACLs

```bash
getfacl /var/log/nginx/
```

### Verify Group Membership

```bash
# On the server
id username

# From AD (if you have AD tools)
Get-ADGroupMember "ps-zzzapp-tst1-app_restricted"
```

### Test Access

```bash
# As the user
sudo -u username ls -l /var/log/nginx/
```

## Common Scenarios

### Scenario 1: New Web Server

1. Create AD groups:
```bash
ansible-playbook -i localhost, playbooks/1_create_ad_groups.yml \
  -e "hostname=ps-zzzapp-tst2" \
  -e "ad_ou_path=OU=Groups,OU=Servers,DC=example,DC=com"
```

2. Apply nginx profile (uses default group):
```bash
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml \
  -l "ps-zzzapp-tst2"
```

### Scenario 2: Grant Team Access

1. Add team AD group to server's app-restricted group in AD
2. Run playbook to apply file permissions:
```bash
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml \
  -l "ps-zzzapp-tst2"
```

### Scenario 3: Service Account Access

```bash
ansible-playbook -i inventory playbooks/application_profile_examples/nginx-webserver.yml \
  -e "user_name=svc.XX.nginx.deploy.prd" \
  -l "ps-zzzapp-tst*"
```

### Scenario 4: Access Profile Generated from an Install Footprint (cairn)

A team installed their application on a build host; cairn captured the
footprint and exported the access profile (services, timers, quadlets, unit
files, folders, ownership). Apply it with the team's group:

```bash
# On the build host (once, after the install):
sudo cairn footprint --config cairn-footprint-linux.yaml \
  --app myapp --report footprint-myapp.json --access-vars myapp-access.yml

# Review myapp-access.yml, then apply:
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @myapp-access.yml -e "group_name=ps-zzzapp-tst1-app_restricted" \
  -l "ps-zzzapp-tst1"

# Remove later with the same inputs:
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @myapp-access.yml -e "group_name=ps-zzzapp-tst1-app_restricted" \
  -l "ps-zzzapp-tst1" --tags cleanup
```

The team can then administer exactly the systemd services, timers, and
quadlets they installed — and the folders that got set up — nothing else.
See `docs/declarative-systemd-access.md` for the full workflow and diagrams.

## Additional Resources

- **Main Documentation**: See `README.md` for comprehensive guide
- **Application deployment lifecycle**: See `docs/application-deployment-lifecycle.md` (Packer builds, handover baseline, setup window, review gate, flip to restricted admin)
- **Per-application guides**: See `docs/applications/` (httpd + a menu of dnf web servers and databases — install, drop-in setup, admin, and before/after access)
- **Declarative systemd access workflow**: See `docs/declarative-systemd-access.md` (cairn pipeline, diagrams, security tradeoffs)
- **Role Documentation**: See `roles/declarative_access/README.md` for role details
- **Example generated profile**: See `examples/myapp-access.yml`
- **Molecule Tests**: See `molecule/` directories for testing examples
