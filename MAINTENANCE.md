# MAINTENANCE.md

_This file serves as a reference for the maintenance procedures and guidelines for the C8 SM checks in this project._
_Note: Please keep this document updated with any changes in maintenance procedures, dependencies, actions, or restrictions._

## Maintenance Procedures

We follow the release process described in the [Camunda Deployment References maintenance guide](https://github.com/camunda/camunda-deployment-references/blob/main/MAINTENANCE.md).

### Before New Releases

- Ensure all `TODO [release-duty]` items are resolved.

- Tag a new version (note: we do not use the branch system).

- Update documentation related to new features or changes.
    - `README.md`
    - Official Camunda documentation ([camunda-docs repository](https://github.com/camunda/camunda-docs/)):
        - [C8SM: Troubleshooting](https://github.com/camunda/camunda-docs/blob/main/docs/self-managed/operational-guides/troubleshooting.md)
        - Search for references to this repository and update the tag version

- Make internal announcements on Slack regarding upcoming releases.
    - `#infex-internal`
    - `#engineering` if relevant

### Bug Fixes on Old Versions

If a bug needs to be fixed on an older version:
- Create a dedicated branch for that version.
- Apply the fix and tag it with a patch version (e.g., `1.2.4`).

### After New Releases

_Nothing referenced yet._

## Dependencies

### Upstream Dependencies: dependencies of this project

None referenced yet.

### Downstream Dependencies: things that depend on this project

None referenced yet.

## Actions

- Notify the **Product Management Team** of any new releases, especially if there are breaking changes or critical updates.

## Restrictions

- N/A
