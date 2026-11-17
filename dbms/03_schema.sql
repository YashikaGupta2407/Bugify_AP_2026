-- =====================================================================
-- Bugify — final relational schema (AP, checkpoint 2)
-- Target engine: PostgreSQL 15 (runs on 14+)
--
-- This is the implemented application schema, translated from the ORM
-- definition in backend/prisma/schema.prisma. Table and column names are
-- quoted exactly as Prisma creates them ("User", "createdAt", ...) so this
-- file matches the live database the Bugify backend connects to.
--
-- Reconciles dbms/01_normalization.md, which proposed a normalised model
-- for the product description before the application schema existed.
-- Mapping from the proposed model to the implemented tables:
--
--   User                 -> "User"
--   Project              -> "Problem"          (a project is a coding problem)
--   ProgrammingLanguage  -> "Language"
--   CodeSubmission       -> "Submission"
--   ExecutionRun         -> "SubmissionResult"
--   ErrorDiagnostic      -> columns of "SubmissionResult"
--                            (errorType, errorMessage, stderr, compileOutput)
--   Explanation          -> "DebuggingExplanation"
--   FixSuggestion        -> "suggestion" + "correctedCode"
--                            columns of "DebuggingExplanation"
--
-- Three tables exist in the implementation that the proposed model did
-- not anticipate, and they are kept because the app depends on them:
--   "TestCase"              expected input/output for a problem
--   "UserProgress"          per-user submission counters (1:1 with "User")
--   "ExtensionDebugSession" diagnostics captured from the VS Code extension
--
-- Normalisation notes:
--   * No repeating groups: one row per result, per explanation, per
--     diagnostic session.
--   * No partial dependencies: every non-key column depends on the whole
--     primary key of its table.
--   * No transitive dependencies: "Language".name is stored once and
--     referenced by id; a user's email is stored once on "User" rather
--     than repeated on every submission.
--   * Candidate keys ("email" on "User", "name" on "Language") are
--     enforced with UNIQUE constraints.
--
-- Run with:  psql -d bugify -f dbms/03_schema.sql
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- "User" — every developer account. 1:1 with "UserProgress".
-- ---------------------------------------------------------------------
CREATE TABLE "User" (
    "id"        SERIAL PRIMARY KEY,
    "name"      TEXT NOT NULL,
    "email"     TEXT NOT NULL,
    "password"  TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "User_email_key" UNIQUE ("email")
);

-- ---------------------------------------------------------------------
-- "Problem" — a coding challenge. 1:N "TestCase", 1:N "Submission".
-- ---------------------------------------------------------------------
CREATE TABLE "Problem" (
    "id"          SERIAL PRIMARY KEY,
    "title"       TEXT NOT NULL,
    "description" TEXT NOT NULL,
    "difficulty"  TEXT NOT NULL,
    "createdAt"   TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- "Language" — supported language + version. Referenced by "Submission".
-- ---------------------------------------------------------------------
CREATE TABLE "Language" (
    "id"      SERIAL PRIMARY KEY,
    "name"    TEXT NOT NULL,
    "version" TEXT NOT NULL,
    CONSTRAINT "Language_name_key" UNIQUE ("name")
);

-- ---------------------------------------------------------------------
-- "Submission" — one piece of code submitted by a user in one language.
-- "problemId" is optional: the API also accepts code without a problem.
-- ---------------------------------------------------------------------
CREATE TABLE "Submission" (
    "id"         SERIAL PRIMARY KEY,
    "userId"     INTEGER NOT NULL,
    "problemId"  INTEGER,
    "languageId" INTEGER NOT NULL,
    "code"       TEXT NOT NULL,
    "createdAt"  TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "Submission_userId_fkey"
        FOREIGN KEY ("userId") REFERENCES "User" ("id")
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT "Submission_problemId_fkey"
        FOREIGN KEY ("problemId") REFERENCES "Problem" ("id")
        ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT "Submission_languageId_fkey"
        FOREIGN KEY ("languageId") REFERENCES "Language" ("id")
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- "SubmissionResult" — the outcome of running one submission.
-- Exactly one result per submission (UNIQUE on "submissionId").
-- ---------------------------------------------------------------------
CREATE TABLE "SubmissionResult" (
    "id"            SERIAL PRIMARY KEY,
    "submissionId"  INTEGER NOT NULL,
    "status"        TEXT NOT NULL,
    "errorType"     TEXT,
    "errorMessage"  TEXT,
    "output"        TEXT,
    "executionTime" DOUBLE PRECISION,
    "memory"        DOUBLE PRECISION,
    "stderr"        TEXT,
    "compileOutput" TEXT,
    "createdAt"     TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SubmissionResult_submissionId_key" UNIQUE ("submissionId"),
    CONSTRAINT "SubmissionResult_status_check"
        CHECK ("status" IN ('success', 'error')),
    CONSTRAINT "SubmissionResult_submissionId_fkey"
        FOREIGN KEY ("submissionId") REFERENCES "Submission" ("id")
        ON DELETE CASCADE ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- "DebuggingExplanation" — why the code failed and how to fix it.
-- At most one explanation per result (UNIQUE on "submissionResultId").
-- ---------------------------------------------------------------------
CREATE TABLE "DebuggingExplanation" (
    "id"                 SERIAL PRIMARY KEY,
    "submissionResultId" INTEGER NOT NULL,
    "summary"            TEXT NOT NULL,
    "cause"              TEXT NOT NULL,
    "location"           TEXT,
    "explanation"        TEXT NOT NULL,
    "suggestion"         TEXT NOT NULL,
    "correctedCode"      TEXT,
    "createdAt"          TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "DebuggingExplanation_submissionResultId_key"
        UNIQUE ("submissionResultId"),
    CONSTRAINT "DebuggingExplanation_submissionResultId_fkey"
        FOREIGN KEY ("submissionResultId") REFERENCES "SubmissionResult" ("id")
        ON DELETE CASCADE ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- "TestCase" — expected input/output pairs for a problem.
-- ---------------------------------------------------------------------
CREATE TABLE "TestCase" (
    "id"             SERIAL PRIMARY KEY,
    "problemId"      INTEGER NOT NULL,
    "input"          TEXT NOT NULL,
    "expectedOutput" TEXT NOT NULL,
    CONSTRAINT "TestCase_problemId_fkey"
        FOREIGN KEY ("problemId") REFERENCES "Problem" ("id")
        ON DELETE CASCADE ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- "UserProgress" — running counters per user, one row per user.
-- ---------------------------------------------------------------------
CREATE TABLE "UserProgress" (
    "id"                    SERIAL PRIMARY KEY,
    "userId"                INTEGER NOT NULL,
    "totalSubmissions"      INTEGER NOT NULL DEFAULT 0,
    "successfulSubmissions" INTEGER NOT NULL DEFAULT 0,
    "failedSubmissions"     INTEGER NOT NULL DEFAULT 0,
    "updatedAt"             TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "UserProgress_userId_key" UNIQUE ("userId"),
    CONSTRAINT "UserProgress_counts_check"
        CHECK ("totalSubmissions" >= 0
               AND "successfulSubmissions" >= 0
               AND "failedSubmissions" >= 0
               AND "totalSubmissions" = "successfulSubmissions" + "failedSubmissions"),
    CONSTRAINT "UserProgress_userId_fkey"
        FOREIGN KEY ("userId") REFERENCES "User" ("id")
        ON DELETE CASCADE ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- "ExtensionDebugSession" — one diagnostic captured from the VS Code
-- extension. Independent of "Submission": an editor diagnostic has no
-- execution result, only the analysed text.
-- ---------------------------------------------------------------------
CREATE TABLE "ExtensionDebugSession" (
    "id"               SERIAL PRIMARY KEY,
    "userId"           INTEGER NOT NULL,
    "workspaceName"    TEXT,
    "filePath"         TEXT NOT NULL,
    "language"         TEXT NOT NULL,
    "errorType"        TEXT,
    "errorMessage"     TEXT,
    "diagnosticCode"   TEXT,
    "diagnosticSource" TEXT,
    "line"             INTEGER,
    "severity"         TEXT,
    "analysisSource"   TEXT NOT NULL,
    "aiExplanation"    JSONB,
    "resolved"         BOOLEAN NOT NULL DEFAULT FALSE,
    "createdAt"        TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "ExtensionDebugSession_analysisSource_check"
        CHECK ("analysisSource" IN ('ai', 'rules')),
    CONSTRAINT "ExtensionDebugSession_userId_fkey"
        FOREIGN KEY ("userId") REFERENCES "User" ("id")
        ON DELETE CASCADE ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- Supporting indexes
--
-- PostgreSQL does not create an index for a foreign key automatically, and
-- the ORM definition does not declare any @@index, so the indexes below
-- are added here for the joins the application actually performs.
-- Mirror them as @@index in backend/prisma/schema.prisma if the project
-- later moves to Prisma-managed migrations, otherwise a future migration
-- may drop them.
-- ---------------------------------------------------------------------
CREATE INDEX "Submission_userId_idx"      ON "Submission" ("userId");
CREATE INDEX "Submission_problemId_idx"   ON "Submission" ("problemId");
CREATE INDEX "Submission_languageId_idx"  ON "Submission" ("languageId");
CREATE INDEX "Submission_createdAt_idx"   ON "Submission" ("createdAt");
CREATE INDEX "TestCase_problemId_idx"     ON "TestCase" ("problemId");
CREATE INDEX "SubmissionResult_status_idx" ON "SubmissionResult" ("status");
CREATE INDEX "ExtensionDebugSession_userId_idx"     ON "ExtensionDebugSession" ("userId");
CREATE INDEX "ExtensionDebugSession_createdAt_idx" ON "ExtensionDebugSession" ("createdAt");

COMMIT;
