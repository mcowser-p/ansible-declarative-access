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
        // release. Requires the GALAXY_API_KEY repository secret (Galaxy ->
        // Collections -> API token, signed in as mcowser-p, which owns the
        // mcowser_p namespace) exported in .github/workflows/release.yml.
        publishCmd:
          "ansible-galaxy collection publish mcowser_p-linux_access-${nextRelease.version}.tar.gz --token $GALAXY_API_KEY",
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
