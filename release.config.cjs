module.exports = {
  branches: ['main'],
  tagFormat: 'v${version}',
  plugins: [
    [
      '@semantic-release/commit-analyzer',
      { preset: 'conventionalcommits' },
    ],
    [
      '@semantic-release/release-notes-generator',
      { preset: 'conventionalcommits' },
    ],
    [
      '@semantic-release/exec',
      {
        prepareCmd:
          'bash scripts/prepare-release.sh "${nextRelease.version}" "${nextRelease.gitTag}"',
        successCmd:
          'printf "release_tag=%s\\n" "${nextRelease.gitTag}" >> "$GITHUB_OUTPUT"',
      },
    ],
    [
      '@semantic-release/github',
      {
        assets: [
          {
            path: 'release-assets/PolyDrom.dmg',
            label: 'PolyDrom installer (Apple silicon)',
          },
          {
            path: 'release-assets/PolyDrom.dmg.sha256',
            label: 'SHA-256 checksum',
          },
          {
            path: 'release-assets/appcast.xml',
            label: 'Sparkle update feed',
          },
        ],
        successCommentCondition: false,
        failCommentCondition: false,
        releasedLabels: false,
      },
    ],
  ],
};
