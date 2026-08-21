// .releaserc.js
module.exports = {
  branches: ["main"],
  tagFormat: `v\${version}`,
  plugins: [
    [
      "@semantic-release/commit-analyzer",
      {
        preset: "angular",
        releaseRules: [
          // Ignore commits without <scope>
          { scope: null, release: false },

          // Major release: breaking changes
          { breaking: true, release: "major" },
          // Minor release: new features
          { type: "feat", release: "minor" },
          // Patch release: bug fixes
          { type: "fix", release: "patch" },
          { type: "docs", release: "patch" },
          { type: "patch", release: "patch" },
          // Other types: ignore
          { type: "chore", release: false },
        ],
      },
    ],
    [
      // Stamp the release version into galaxy.yml and build the collection
      // artifact so the tarball attached to the release matches the tag.
      "@semantic-release/exec",
      {
        prepareCmd:
          "sed -i 's/^version: .*/version: ${nextRelease.version}/' galaxy.yml && ansible-galaxy collection build --force",
        // --- Ansible Galaxy publish (DISABLED until prerequisites are met) ---
        // Runs only when a release is actually cut, right after the GitHub
        // release. To enable:
        //   1. galaxy.yml `license` must be an OSI/SPDX license that
        //      galaxy.ansible.com accepts (LicenseRef-Proprietary is
        //      rejected at import).
        //   2. Sign in to https://galaxy.ansible.com with the mcowser-p
        //      GitHub account (claims the `mcowser_p` namespace — Galaxy
        //      maps the dash to an underscore) and create an API token
        //      under Collections -> API token.
        //   3. Add the token as the GALAXY_API_KEY repository secret and
        //      uncomment the env line in .github/workflows/release.yml.
        //   4. Uncomment the publishCmd below.
        // publishCmd:
        //   "ansible-galaxy collection publish mcowser_p-linux_access-${nextRelease.version}.tar.gz --token $GALAXY_API_KEY",
      },
    ],
    [
      "@semantic-release/github",
      {
        successCommentCondition: false,
        failCommentCondition: false,
        assets: [
          { path: "mcowser_p-linux_access-*.tar.gz", label: "Ansible collection (mcowser_p.linux_access)" },
        ],
      },
    ],
  ],
};
