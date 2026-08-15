# Project Instructions

## Commit messages

- Generate commit messages in Conventional Commits format: `<type>(<optional-scope>): <description>`.
- Derive the message from the actual diff. Describe the user-visible outcome or the reason for the change, not the editing process.
- Use `fix` for bug fixes, `perf` for performance improvements, and `feat` for new functionality; these trigger patch, patch, and minor releases respectively. Use an appropriate non-release type such as `docs`, `test`, `refactor`, `build`, `ci`, `style`, or `chore` for other changes.
- Keep the subject concise, imperative, lowercase, and without a trailing period. Add a body only when the motivation or important behavior is not clear from the subject.
- Mark breaking changes with `!` after the type or scope and include a `BREAKING CHANGE:` footer explaining the impact and migration path.
- Keep each commit focused on one logical change. Examples: `fix(playback): resume after reconnect`, `feat(library): add album shuffle`, `ci: disable persisted checkout credentials`.
