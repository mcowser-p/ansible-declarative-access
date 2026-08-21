# Setting File Access (One-Off ACL Grants)

This guide covers using the pre-built playbooks in `playbooks/setting_file_access_examples/` to grant targeted file and folder access. These are for one-off, ad-hoc ACL grants -- not full application profiles.

**When to use these vs application profiles:**

| Scenario | Use |
|----------|-----|
| Full application stack (nginx, httpd, etc.) with sudo + ACLs | [Application profiles](../playbooks/application_profile_examples/) |
| One-off: grant a team read access to a log directory | These playbooks |
| One-off: grant a service account write access to a deploy folder | These playbooks |

---

## Group vs Service Account Access

Use **group playbooks** when an AD group (team) needs access. Use **user playbooks** when a service account needs access.

| Use Case | Entity | Playbook Dir | Example Entity |
|----------|--------|-------------|----------------|
| Team needs to read logs | AD group | `group/` | `ps-webadmins` |
| Server's default app group | AD group | `group/` | `{hostname}-app_restricted` |
| CI/CD deploy pipeline | Service account | `user/` | `svc.XX.nginx.deploy.prd` |
| Monitoring agent | Service account | `user/` | `svc.XX.myapp.monitor.prd` |
| Backup job | Service account | `user/` | `svc.XX.myapp.backup.prd` |
| Config management automation | Service account | `user/` | `svc.XX.myapp.config.prd` |

**Key difference:** Group playbooks default to the server's `{hostname}-app_restricted` group if `group_name` is not specified. User playbooks always require `user_name`.

---

## Available Playbooks

### Group Access

| Playbook | Required Variable | ACL Set | Use Case |
|----------|-------------------|---------|----------|
| `group/grant-GROUP-file-read-access.yml` | `read_file` | `r--` on file | Read a config file |
| `group/grant-GROUP-file-modify-access.yml` | `modify_file` | `rw-` on file | Edit a config file |
| `group/grant-GROUP-folder-read-access.yml` | `read_folder` | `rX` recursive | Browse logs, read configs |
| `group/grant-GROUP-folder-write-access.yml` | `write_folder` | `rwX` recursive | Manage a config directory |

Optional variable: `group_name` (defaults to `{hostname}-app_restricted`)

### Service Account (User) Access

| Playbook | Required Variables | ACL Set | Use Case |
|----------|-------------------|---------|----------|
| `user/grant-USER-file-read-access.yml` | `user_name`, `read_file` | `r--` on file | Service reads a config |
| `user/grant-USER-file-modify-access.yml` | `user_name`, `modify_file` | `rw-` on file | Service writes state file |
| `user/grant-USER-folder-read-access.yml` | `user_name`, `read_folder` | `rX` recursive | Service reads log dir |
| `user/grant-USER-folder-write-access.yml` | `user_name`, `write_folder` | `rwX` recursive | Deploy account writes content |

All playbooks accept `target_hosts` to override the default `all` host pattern.

---

## Group Access Examples

### Using the default server group (simplest)

When you don't pass `group_name`, the playbook automatically uses the server's `{hostname}-app_restricted` group:

```bash
# Grant the server's default group read access to httpd logs
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/group/grant-GROUP-folder-read-access.yml \
  -e "read_folder=/var/log/httpd"
```

### Using a custom AD group

```bash
# Grant a specific team read access to nginx logs
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/group/grant-GROUP-folder-read-access.yml \
  -e "group_name=ps-webadmins" \
  -e "read_folder=/var/log/nginx"
```

### All four group permission types

```bash
# File read -- team can read a specific config file
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/group/grant-GROUP-file-read-access.yml \
  -e "group_name=ps-webadmins" \
  -e "read_file=/etc/nginx/nginx.conf"

# File modify -- team can edit a specific config file
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/group/grant-GROUP-file-modify-access.yml \
  -e "group_name=ps-webadmins" \
  -e "modify_file=/etc/nginx/conf.d/custom.conf"

# Folder read -- team can browse and read all files in a directory (recursive)
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/group/grant-GROUP-folder-read-access.yml \
  -e "group_name=ps-webadmins" \
  -e "read_folder=/var/log/nginx"

# Folder write -- team can read, write, and create files in a directory (recursive)
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/group/grant-GROUP-folder-write-access.yml \
  -e "group_name=ps-webadmins" \
  -e "write_folder=/etc/nginx/conf.d"
```

### Targeting specific hosts

```bash
# Only apply to production web servers
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/group/grant-GROUP-folder-read-access.yml \
  -e "read_folder=/var/log/httpd" \
  -l "ps-zzzapp-tst*"

# Single host
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/group/grant-GROUP-folder-read-access.yml \
  -e "read_folder=/var/log/httpd" \
  -l "ps-zzzapp-tst1"
```

---

## Service Account Examples

Service accounts (e.g., `svc.XX.nginx.deploy.prd`, `svc.XX.myapp.monitor.prd`) are AD user accounts used by automated processes. Use the `user/` playbooks for these.

### Deploy account -- write access to web content

A CI/CD pipeline deploys content to `/var/www/html`:

```bash
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/user/grant-USER-folder-write-access.yml \
  -e "user_name=svc.XX.nginx.deploy.prd" \
  -e "write_folder=/var/www/html"
```

### Monitoring account -- read access to application logs

A monitoring agent needs to read application logs:

```bash
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/user/grant-USER-folder-read-access.yml \
  -e "user_name=svc.XX.myapp.monitor.prd" \
  -e "read_folder=/var/log/myapp"
```

### Backup account -- read access to data directory

A backup job needs to read application data:

```bash
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/user/grant-USER-folder-read-access.yml \
  -e "user_name=svc.XX.myapp.backup.prd" \
  -e "read_folder=/opt/app/data"
```

### Config management -- service account edits a single file

An automation tool needs to update a specific config file:

```bash
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/user/grant-USER-file-modify-access.yml \
  -e "user_name=svc.XX.myapp.config.prd" \
  -e "modify_file=/etc/myapp/settings.yml"
```

### Multiple access grants for the same service account

Run multiple playbooks to build up the access a service account needs:

```bash
# svc.XX.myapp.deploy.prd needs to: read config, write content, read logs
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/user/grant-USER-file-read-access.yml \
  -e "user_name=svc.XX.myapp.deploy.prd" \
  -e "read_file=/etc/myapp/app.conf"

ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/user/grant-USER-folder-write-access.yml \
  -e "user_name=svc.XX.myapp.deploy.prd" \
  -e "write_folder=/var/www/html"

ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/user/grant-USER-folder-read-access.yml \
  -e "user_name=svc.XX.myapp.deploy.prd" \
  -e "read_folder=/var/log/myapp"
```

These are additive -- each playbook adds ACLs without affecting the others.

---

## What Gets Set on Disk

After running a playbook, here's what the ACLs look like. Use `getfacl` to verify.

### File read (`r`)

```bash
$ getfacl /etc/httpd/conf/httpd.conf
# file: etc/httpd/conf/httpd.conf
user::rw-
group::r--
group:ps-webadmins:r--       # <-- read only
mask::r--
other::r--
```

### File modify (`rw`)

```bash
$ getfacl /etc/nginx/conf.d/custom.conf
# file: etc/nginx/conf.d/custom.conf
user::rw-
group::r--
group:ps-webadmins:rw-       # <-- read + write
mask::rw-
other::r--
```

### Folder read (`rX` -- recursive)

Directories get `r-x` (read + traverse). Files inside get `r--` (read only). Scripts that already have the execute bit get `r-x`.

```bash
$ getfacl /var/log/httpd/
# file: var/log/httpd/
user::rwx
group::r-x
group:ps-webadmins:r-x       # <-- read + traverse on directory
mask::r-x
other::r-x
default:group:ps-webadmins:r-x  # <-- new files inherit

$ getfacl /var/log/httpd/access_log
# file: var/log/httpd/access_log
user::rw-
group::r--
group:ps-webadmins:r--       # <-- read only on regular file
mask::r--
other::r--
```

### Folder modify (`rwX` -- recursive)

Directories get `rwx` (full access). Files inside get `rw-` (read + write). Scripts that already have the execute bit get `rwx`.

```bash
$ getfacl /etc/httpd/conf.d/
# file: etc/httpd/conf.d/
user::rwx
group::r-x
group:ps-webadmins:rwx       # <-- full access on directory
mask::rwx
other::r-x
default:group:ps-webadmins:rwx  # <-- new files inherit

$ getfacl /etc/httpd/conf.d/custom.conf
# file: etc/httpd/conf.d/custom.conf
user::rw-
group::r--
group:ps-webadmins:rw-       # <-- read + write on regular file
mask::rw-
other::r--
```

### How `rX` and `rwX` handle scripts vs regular files

The capital `X` means "set execute only if the file already has the execute bit set." This matters for scripts:

| File Type | `rX` (declarative_access_folders_read) | `rwX` (declarative_access_folders_modify) |
|-----------|--------------------|-----------------------|
| Directory | `r-x` | `rwx` |
| Regular file (`.txt`, `.conf`, `.log`) | `r--` | `rw-` |
| Script with execute bit (`.sh`) | `r-x` | `rwx` |

This prevents accidentally granting execute on config files and log files while still allowing scripts to be run.

---

## How to Verify Access

### Check ACLs on a file or directory

```bash
# View ACLs
getfacl /var/log/httpd/
getfacl /etc/nginx/nginx.conf

# Look for your group or user in the output
getfacl /var/log/httpd/ | grep webadmins
getfacl /var/log/httpd/ | grep svc.XX.myapp.monitor.prd
```

### Test actual access as a service account

```bash
# Test read access
sudo -u svc.XX.myapp.monitor.prd cat /var/log/myapp/application.log

# Test write access
sudo -u svc.XX.nginx.deploy.prd touch /var/www/html/test-write
sudo -u svc.XX.nginx.deploy.prd rm /var/www/html/test-write

# Test directory listing
sudo -u svc.XX.myapp.backup.prd ls -la /opt/app/data/

# Test that write is denied on a read-only folder
sudo -u svc.XX.myapp.monitor.prd echo "test" >> /var/log/myapp/application.log
# Should fail with "Permission denied"
```

### Check group membership

```bash
# On the server
id svc.XX.nginx.deploy.prd

# Verify AD group resolution
getent group ps-webadmins@example.com
```

---

## Important Notes

### No built-in ACL cleanup

These playbooks only **add** ACLs. To remove ACLs, use `setfacl` manually:

```bash
# Remove a specific group's ACL from a file
setfacl -x g:ps-webadmins /etc/nginx/nginx.conf

# Remove a specific user's ACL from a file
setfacl -x u:svc.XX.myapp.monitor.prd /var/log/myapp/application.log

# Remove all ACLs from a directory (recursive)
setfacl -R -b /var/log/httpd/
```

### Traversal ACLs on parent directories

When you grant folder access to `/var/log/httpd/`, the role automatically sets `rX` (traverse) permissions on parent directories so the user can actually reach the target path. It skips the first two path levels (`/` and `/var`) for security.

For the path `/var/log/httpd/`:
- `/` -- not modified
- `/var` -- not modified
- `/var/log` -- gets `rX` traverse ACL added

### Symlinks are resolved

If you pass a symlink as the target path, the role resolves it to the actual file/directory before setting ACLs. The ACLs are set on the real path, not the symlink.

### Default ACLs on directories

When granting folder access, both regular and default ACLs are set. Default ACLs mean **new files created inside the directory automatically inherit the same permissions**. You don't need to re-run the playbook when new files appear.

### Access is additive

Running multiple playbooks for different paths on the same group or service account is safe. Each playbook adds its own ACL entries without removing existing ones.

### Always test with check mode first

```bash
ansible-playbook -i inventory \
  playbooks/setting_file_access_examples/group/grant-GROUP-folder-read-access.yml \
  -e "read_folder=/var/log/httpd" \
  --check
```

---

## Additional Resources

- [Role Documentation](../roles/declarative_access/README.md) -- full variable reference, execution flow, and feature details
- [Application Profiles](../playbooks/application_profile_examples/) -- pre-built profiles for common applications (nginx, httpd, TLS)
- [General Usage Examples](example-usage.md) -- broader guide covering AD groups, profiles, and advanced usage
