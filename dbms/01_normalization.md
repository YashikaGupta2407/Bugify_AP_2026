# Bugify database normalization

## Scope and assumptions

This design models Bugify as described in the repository: a platform where a developer submits code, inspects execution failures, reads explanations and reviews possible fixes. The repository currently contains no application schema or source files, so the following is a proposed relational model based on that product description. It assumes each submission belongs to one user and one project, each project uses one programming language, a submission can be run multiple times, and a run may produce multiple errors and suggestions. Source code and diagnostic text are stored as text fields; arrays of errors, explanations or suggestions are not stored in one column.

## Initial unnormalized form

A single debugging record could initially be represented as:

`DebugRecord(user_id, user_email, project_id, project_name, submission_id, source_code, language_name, run_id, run_status, error_type, error_message, line_number, explanation_text, model_name, suggestion_text, suggested_at)`

A submission may have repeated runs; each run may have repeated errors; each error may have repeated explanations and fix suggestions. Saving those lists in one field violates 1NF. Flattening them into repeated rows produces duplicate user, project, submission, run and error data. A flattened key such as `(submission_id, run_id, error_id, suggestion_id)` also causes partial dependencies: user/project/submission fields depend only on submission, run fields depend only on run, error fields depend only on error, and suggestion fields depend only on suggestion.

## First normal form

Make every value atomic and represent each repeated run, error, explanation and suggestion as its own row. One possible flattened relation is:

`DebugEvent(submission_id, run_id, error_id, explanation_id, suggestion_id, user_id, user_email, project_id, project_name, source_code, language_name, run_status, started_at, error_type, error_message, line_number, explanation_text, model_name, suggestion_text, suggested_at)`

Candidate key: `(submission_id, run_id, error_id, explanation_id, suggestion_id)` for a row containing a suggestion. This removes repeating groups, but duplicates submission and parent facts and has partial dependencies, so it is not yet 2NF.

## Second normal form

Separate facts that depend on a proper subset of the flattened composite key:

- `Submission(submission_id, user_id, user_email, project_id, project_name, source_code, language_name, submitted_at)`
- `ExecutionRun(run_id, submission_id, run_status, started_at, completed_at, exit_code, stdout, stderr)`
- `Error(error_id, run_id, error_type, error_message, line_number, column_number, stack_trace)`
- `Explanation(explanation_id, error_id, explanation_text, model_name, generated_at)`
- `FixSuggestion(suggestion_id, explanation_id, suggestion_text, created_at)`

This removes partial dependencies from the original composite event row. The submission relation still contains transitive dependencies such as `submission_id → project_id → project_name` and `submission_id → language_id → language_name`; those are handled in 3NF.

## Third normal form

The final relations and keys are:

| Relation | Primary key | Functional dependencies |
|---|---|---|
| `User(user_id, email, display_name, created_at)` | `user_id` | `user_id → email, display_name, created_at`; `email → user_id, display_name, created_at` |
| `Project(project_id, user_id, project_name, created_at)` | `project_id` | `project_id → user_id, project_name, created_at` |
| `ProgrammingLanguage(language_id, language_name)` | `language_id` | `language_id → language_name`; `language_name → language_id` |
| `CodeSubmission(submission_id, project_id, language_id, source_code, submitted_at)` | `submission_id` | `submission_id → project_id, language_id, source_code, submitted_at` |
| `ExecutionRun(run_id, submission_id, run_status, started_at, completed_at, exit_code, stdout, stderr)` | `run_id` | `run_id → submission_id, run_status, started_at, completed_at, exit_code, stdout, stderr` |
| `ErrorDiagnostic(error_id, run_id, error_type, error_message, line_number, column_number, stack_trace)` | `error_id` | `error_id → run_id, error_type, error_message, line_number, column_number, stack_trace` |
| `Explanation(explanation_id, error_id, explanation_text, model_name, generated_at)` | `explanation_id` | `explanation_id → error_id, explanation_text, model_name, generated_at` |
| `FixSuggestion(suggestion_id, explanation_id, suggestion_text, created_at)` | `suggestion_id` | `suggestion_id → explanation_id, suggestion_text, created_at` |

Foreign keys: `Project.user_id → User.user_id`; `CodeSubmission.project_id → Project.project_id`; `CodeSubmission.language_id → ProgrammingLanguage.language_id`; `ExecutionRun.submission_id → CodeSubmission.submission_id`; `ErrorDiagnostic.run_id → ExecutionRun.run_id`; `Explanation.error_id → ErrorDiagnostic.error_id`; `FixSuggestion.explanation_id → Explanation.explanation_id`. `User.email` and `ProgrammingLanguage.language_name` are unique candidate keys. Other names are not assumed unique.

In each final relation every non-key attribute depends on the whole key and nothing but a key. There are no non-key determinants, so these relations also satisfy BCNF under the stated functional dependencies. If the product later allows a project to use multiple languages, language must move from `CodeSubmission` to an explicit project-language or submission-language association based on actual behavior.

## Why the decomposition helps

- User and project names are stored once, preventing email or project-name updates from needing edits in every run.
- A submission can have many execution runs without copying the source code into each run row.
- A run can produce multiple diagnostic records, and one diagnostic can receive multiple explanations or suggestions without repeating the run payload.
- Language names are maintained once and referenced by key.
- Each child row can be deleted or queried independently while foreign keys preserve the parent relationship.

The exact fields and constraints should be reconciled with the implemented app before `dbms/03_schema.sql` is finalized.
