# Changelog

## 1.0.0

`notify_deploy_qawolf` now reports deployments through the public
`deployment.reportStatus` API instead of the legacy `deploy_success` webhook.

0.x reported to a webhook that newer workspaces have nothing listening on, so
builds recorded nothing and started no runs. 1.0.0 reports through the API
those workspaces do evaluate.

### Breaking

- **A deployment that matches no trigger now succeeds.** 0.x failed the lane
  with "no matched trigger". 1.0.0 records the deployment, starts no runs and
  still succeeds — the lane goes green while nothing is tested. Before
  upgrading, confirm with your QA Wolf representative that a trigger exists for
  this deployment, and check the `environment` value: a name matching no
  environment creates one, which no trigger is attached to.
- **`workspace_id` is new and required.** A team API key does not imply the
  workspace, so every call must name it. It can also come from the
  `QAWOLF_WORKSPACE_ID` environment variable.
- **`environment` is new and required, and `deployment_type` is removed.**
  `deployment_type` was an opaque identifier matched by a legacy trigger's
  configuration. `environment` names a QA Wolf environment, by its name or one
  of its aliases. A value matching no environment **creates** one, so the old
  value is not carried across automatically: passing `deployment_type` now
  fails with an explanation. Check the value against the environments in your
  workspace before upgrading.
- **`deduplication_key` is removed.** A deployment is identified by
  `provider_deployment_id`, which the plugin derives from your CI system's own
  environment variables (GitHub Actions, GitLab CI, CircleCI, Buildkite,
  Jenkins, Bitbucket Pipelines) and which you can set explicitly. Reports
  sharing one identifier update a single deployment, and only the first
  `success` report evaluates triggers.
- **`QAWOLF_RUN_ID` is replaced by `QAWOLF_DEPLOYMENT_ID`.** The API answers
  with the deployment, not with runs: runs start asynchronously after the call
  returns, so there is no run id to hand back. The action now sets
  `QAWOLF_DEPLOYMENT_ID` in `ENV` and in
  `Actions.lane_context[SharedValues::QAWOLF_DEPLOYMENT_ID]`, and returns the
  deployment id. `QAWOLF_RUN_ID` is no longer set.
- **`deployment_url` is renamed to `deploy_target`**, and it must be an http or
  https URL. It is required when `environment` names no existing environment,
  because the environment created to hold the deployment serves it.
- **`hosting_service`, `repository_name`, `repository_owner` and
  `repository_namespace` are removed**, replaced by a single `repository`
  option holding the repository's full path, e.g. `my-org/my-app`. QA Wolf
  resolves the code host from the repository you linked to your workspace.

Passing any removed option fails with a message naming its replacement.

### Added

- `status` (`pending`, `success`, `failure`, `inactive`), defaulting to
  `success`, the only status that evaluates triggers. Reporting `pending` and
  then `success` only updates one deployment when both calls report the same
  `provider_deployment_id`, so pass it explicitly where the plugin cannot
  derive one.
- `provider_deployment_discriminator`, appended to the derived identifier to
  separate the deployments one CI job makes at the same time, such as the legs
  of a build matrix. Without it, every leg of a matrix shares one deployment
  and only the first one's runs start.
- `service`, for naming which application was deployed when several services
  deploy into one environment.
- `commit_message` and `commit_author_name`, shown on the deployment in QA Wolf.
- Bitrise and Azure Pipelines are detected when deriving `provider_deployment_id`.
- `QAWOLF_ENVIRONMENT_RUNS_URL`, set in `ENV` and the lane context from the
  `url` the API returns. It links the environment's runs page, not a page for
  this deployment.

### Unchanged

- `upload_to_qawolf` and `inject_qawolf_instrumentation` are untouched.
- `notify_deploy_qawolf` still folds the uploaded executable's path into the
  run's environment variables under `executable_environment_key`, and still
  requires `upload_to_qawolf` to have run (or `executable_filename` to be set).
- `variables`, `branch`, `sha`, `commit_url` and `pull_request_number` keep
  their names and meanings. `merge_request_number` also still works, and is
  reported through the same field as `pull_request_number`.
