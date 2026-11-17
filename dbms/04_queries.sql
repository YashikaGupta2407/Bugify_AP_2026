-- =====================================================================
-- Bugify — Relational Database Query Suite (AP, Checkpoint 3)
-- Target engine: PostgreSQL 15 (runs on 14+)
-- Schema source: dbms/03_schema.sql
--
-- This file contains 10 production-grade SQL queries designed to demonstrate
-- database operations on the Bugify relational schema.
--
-- Queries span from foundational filtering and multi-table joins to complex
-- aggregations, anti-semi-joins, window functions, safe JSONB key
-- introspection, and data integrity auditing.
-- =====================================================================


-- ---------------------------------------------------------------------
-- QUERY 1: Active Error-Severity IDE Diagnostics
-- Category   : Basic Selection & Filtering
-- Concepts   : SELECT, WHERE, boolean filtering, case-insensitive string match,
--              ORDER BY, LIMIT
-- Assumptions: "severity" is an unconstrained TEXT column in ExtensionDebugSession.
--              We explicitly filter for 'error' severity (case-normalized via
--              LOWER(TRIM(...))) to identify compiler/runtime crashes without
--              conflating 'error' with 'warning' or other unverified levels.
-- Purpose    : Retrieve unresolved editor diagnostic sessions where severity is
--              'error' for immediate developer triage.
-- ---------------------------------------------------------------------
SELECT
    eds."id" AS "sessionId",
    eds."userId",
    eds."workspaceName",
    eds."filePath",
    eds."language",
    eds."errorType",
    eds."errorMessage",
    eds."severity",
    eds."analysisSource",
    eds."createdAt"
FROM "ExtensionDebugSession" eds
WHERE eds."resolved" = FALSE
  AND LOWER(TRIM(eds."severity")) = 'error'
ORDER BY eds."createdAt" DESC
LIMIT 50;


-- ---------------------------------------------------------------------
-- QUERY 2: Comprehensive Submission Activity Feed
-- Category   : Multi-Table Joins & Null-Safe Projection
-- Concepts   : INNER JOIN, LEFT JOIN, COALESCE, column aliasing, timestamp sorting
-- Schema Note: Problem.difficulty is verified as TEXT NOT NULL in dbms/03_schema.sql,
--              making COALESCE(p."difficulty", 'N/A') fully type-compatible without casting.
--              Submission.problemId is nullable (allowing ad-hoc code runs), and
--              SubmissionResult is nullable for in-flight/pending executions.
-- Purpose    : Generates an administrative activity feed showing submissions,
--              user identity, problem details, language used, and execution status.
-- ---------------------------------------------------------------------
SELECT
    s."id" AS "submissionId",
    u."name" AS "userName",
    u."email" AS "userEmail",
    COALESCE(p."title", 'Standalone Code') AS "problemTitle",
    COALESCE(p."difficulty", 'N/A') AS "problemDifficulty",
    l."name" AS "languageName",
    COALESCE(sr."status", 'pending') AS "executionStatus",
    sr."executionTime",
    sr."memory",
    s."createdAt" AS "submittedAt"
FROM "Submission" s
INNER JOIN "User" u ON u."id" = s."userId"
INNER JOIN "Language" l ON l."id" = s."languageId"
LEFT JOIN "Problem" p ON p."id" = s."problemId"
LEFT JOIN "SubmissionResult" sr ON sr."submissionId" = s."id"
ORDER BY s."createdAt" DESC;


-- ---------------------------------------------------------------------
-- QUERY 3: Language Runtime & Memory Performance Benchmark
-- Category   : Aggregation, Filtering & Grouping
-- Concepts   : INNER JOIN, GROUP BY, FILTER (WHERE ...), aggregate functions,
--              numeric casting, HAVING
-- Schema Note: INNER JOIN with SubmissionResult guarantees that every row counted
--              possesses an execution outcome. The alias "completedSubmissions"
--              accurately reflects this scope. Runtime metrics (time & memory)
--              are averaged strictly over successful runs to prevent aborted/syntax
--              errors from skewing benchmarks. Languages with completed submissions
--              where no run succeeded will display NULL runtime metrics rather than
--              being silently dropped.
-- Purpose    : Measures execution speed and memory consumption across programming
--              languages for successful runs, filtering out languages without activity.
-- ---------------------------------------------------------------------
SELECT
    l."id" AS "languageId",
    l."name" AS "languageName",
    l."version" AS "languageVersion",
    COUNT(sr."id") AS "completedSubmissions",
    COUNT(sr."id") FILTER (WHERE sr."status" = 'success') AS "successfulRuns",
    ROUND(AVG(sr."executionTime") FILTER (WHERE sr."status" = 'success')::numeric, 3) AS "avgExecutionTimeMs",
    ROUND(MIN(sr."executionTime") FILTER (WHERE sr."status" = 'success')::numeric, 3) AS "minExecutionTimeMs",
    ROUND(MAX(sr."executionTime") FILTER (WHERE sr."status" = 'success')::numeric, 3) AS "maxExecutionTimeMs",
    ROUND(AVG(sr."memory") FILTER (WHERE sr."status" = 'success')::numeric, 2) AS "avgMemoryKb"
FROM "Language" l
INNER JOIN "Submission" s ON s."languageId" = l."id"
INNER JOIN "SubmissionResult" sr ON sr."submissionId" = s."id"
GROUP BY l."id", l."name", l."version"
HAVING COUNT(sr."id") > 0
ORDER BY "avgExecutionTimeMs" ASC NULLS LAST;


-- ---------------------------------------------------------------------
-- QUERY 4: Problem Difficulty Assessment & Failure Rate Analysis
-- Category   : Conditional Aggregations & Ratio Computation
-- Concepts   : LEFT JOIN, GROUP BY, FILTER (WHERE ...), NULLIF division-by-zero guard
-- Schema Note: Failure rate percentage uses completed attempts (COUNT(sr."id")) as the
--              denominator, safely guarded by NULLIF against unattempted problems.
-- Purpose    : Computes real-world developer failure rates per problem to evaluate
--              whether assigned difficulty ratings match empirical developer performance.
-- ---------------------------------------------------------------------
SELECT
    p."id" AS "problemId",
    p."title" AS "problemTitle",
    p."difficulty",
    COUNT(s."id") AS "totalAttempts",
    COUNT(sr."id") AS "completedAttempts",
    COUNT(sr."id") FILTER (WHERE sr."status" = 'success') AS "successfulAttempts",
    COUNT(sr."id") FILTER (WHERE sr."status" = 'error') AS "failedAttempts",
    ROUND(
        100.0 * COUNT(sr."id") FILTER (WHERE sr."status" = 'error') / NULLIF(COUNT(sr."id"), 0),
        2
    ) AS "failureRatePercentage"
FROM "Problem" p
LEFT JOIN "Submission" s ON s."problemId" = p."id"
LEFT JOIN "SubmissionResult" sr ON sr."submissionId" = s."id"
GROUP BY p."id", p."title", p."difficulty"
ORDER BY "failureRatePercentage" DESC NULLS LAST, p."id" ASC;


-- ---------------------------------------------------------------------
-- QUERY 5: Error Frequency & Debugging Explanation Coverage
-- Category   : Grouping, Coverage Tracking & Constraint Verification
-- Concepts   : LEFT JOIN, GROUP BY, COUNT(*), percentage arithmetic, COALESCE
-- Schema Note: DebuggingExplanation has a UNIQUE constraint on "submissionResultId",
--              guaranteeing a strict 1:0..1 relationship. The LEFT JOIN cannot inflate
--              failed submission counts.
-- Purpose    : Categorizes failed execution outcomes by errorType and measures the
--              percentage of errors that received a debugging explanation.
-- ---------------------------------------------------------------------
SELECT
    COALESCE(sr."errorType", 'Unspecified Error') AS "errorType",
    COUNT(*) AS "failedSubmissionsCount",
    COUNT(de."id") AS "explanationsGeneratedCount",
    ROUND(100.0 * COUNT(de."id") / COUNT(*), 2) AS "explanationCoveragePercentage"
FROM "SubmissionResult" sr
LEFT JOIN "DebuggingExplanation" de ON de."submissionResultId" = sr."id"
WHERE sr."status" = 'error'
GROUP BY COALESCE(sr."errorType", 'Unspecified Error')
ORDER BY "failedSubmissionsCount" DESC;


-- ---------------------------------------------------------------------
-- QUERY 6: Language Gap Analysis (Web Submissions vs. IDE Extension)
-- Category   : Anti-Semi-Join & Case-Insensitive String Normalization
-- Concepts   : NOT EXISTS, DISTINCT, LOWER(TRIM(...)), correlated subquery
-- Schema Note: Language.name is cataloged text, while ExtensionDebugSession.language
--              is client-submitted editor text. Case normalization with LOWER(TRIM(...))
--              prevents false negatives. DISTINCT ensures active languages are not duplicated.
-- Purpose    : Identifies actively submitted catalog languages that have no extension
--              diagnostic session with a matching normalized language name.
-- ---------------------------------------------------------------------
SELECT DISTINCT
    l."id" AS "languageId",
    l."name" AS "languageName",
    l."version" AS "languageVersion"
FROM "Language" l
INNER JOIN "Submission" s ON s."languageId" = l."id"
WHERE NOT EXISTS (
    SELECT 1
    FROM "ExtensionDebugSession" eds
    WHERE LOWER(TRIM(eds."language")) = LOWER(TRIM(l."name"))
)
ORDER BY l."name" ASC;


-- ---------------------------------------------------------------------
-- QUERY 7: Problem Quality Assurance & Readiness Audit
-- Category   : Correlated Subqueries & Issue Classification
-- Concepts   : NOT EXISTS, conditional CASE classification, set logic
-- Schema Note: Problems without test cases cannot grade code, and problems without
--              submissions may indicate unpublished or hidden challenges.
-- Purpose    : Administrative QA check classifying incomplete or orphaned problems
--              into three distinct readiness issues.
-- ---------------------------------------------------------------------
SELECT
    p."id" AS "problemId",
    p."title" AS "problemTitle",
    p."difficulty",
    CASE
        WHEN NOT EXISTS (SELECT 1 FROM "TestCase" tc WHERE tc."problemId" = p."id")
         AND NOT EXISTS (SELECT 1 FROM "Submission" s WHERE s."problemId" = p."id")
        THEN 'NO_TEST_CASES_AND_NO_SUBMISSIONS'
        WHEN NOT EXISTS (SELECT 1 FROM "TestCase" tc WHERE tc."problemId" = p."id")
        THEN 'NO_TEST_CASES'
        ELSE 'NO_SUBMISSIONS'
    END AS "qaIssueType"
FROM "Problem" p
WHERE NOT EXISTS (SELECT 1 FROM "TestCase" tc WHERE tc."problemId" = p."id")
   OR NOT EXISTS (SELECT 1 FROM "Submission" s WHERE s."problemId" = p."id")
ORDER BY p."id" ASC;


-- ---------------------------------------------------------------------
-- QUERY 8: Problem Execution Leaderboard (Tie-Preserving Fastest Runtime)
-- Category   : Window Functions & Competitive Ranking
-- Concepts   : CTE, DENSE_RANK() OVER (PARTITION BY ... ORDER BY ...), tie preservation
-- Schema Note: DENSE_RANK() is ordered strictly by sr."executionTime" ASC inside the
--              window function so that equally fast solutions share Rank 1.
--              Deterministic secondary ordering (memory, submission time) is placed
--              only in the outer ORDER BY clause to avoid breaking runtime ties.
-- Purpose    : Identifies the fastest successful solution(s) for each problem, awarding
--              Rank 1 to all solutions tied for top runtime performance.
-- ---------------------------------------------------------------------
WITH FastestSubmissions AS (
    SELECT
        p."id" AS "problemId",
        p."title" AS "problemTitle",
        u."name" AS "userName",
        u."email" AS "userEmail",
        l."name" AS "languageName",
        sr."executionTime",
        sr."memory",
        s."createdAt" AS "submittedAt",
        DENSE_RANK() OVER (
            PARTITION BY s."problemId"
            ORDER BY sr."executionTime" ASC
        ) AS "runtimeRank"
    FROM "Problem" p
    INNER JOIN "Submission" s ON s."problemId" = p."id"
    INNER JOIN "SubmissionResult" sr ON sr."submissionId" = s."id"
    INNER JOIN "User" u ON u."id" = s."userId"
    INNER JOIN "Language" l ON l."id" = s."languageId"
    WHERE sr."status" = 'success'
      AND sr."executionTime" IS NOT NULL
)
SELECT
    "problemId",
    "problemTitle",
    "runtimeRank",
    "userName",
    "userEmail",
    "languageName",
    "executionTime",
    "memory",
    "submittedAt"
FROM FastestSubmissions
WHERE "runtimeRank" = 1
ORDER BY "problemId" ASC, "executionTime" ASC, "submittedAt" ASC;


-- ---------------------------------------------------------------------
-- QUERY 9: Safe AI Diagnostic Introspection & Dynamic JSON Key Discovery
-- Category   : PostgreSQL JSONB Introspection & CTE Consolidation
-- Concepts   : CTE, CROSS JOIN LATERAL jsonb_object_keys, safe CASE guard,
--              jsonb_typeof, outer join consolidation
-- Schema Note: ExtensionDebugSession.aiExplanation is a schemaless JSONB column.
--              Calling jsonb_object_keys() directly on non-objects triggers runtime
--              exceptions. The inline CASE expression guarantees that scalars, arrays,
--              JSON nulls, and SQL NULLs evaluate to '{}'::jsonb, safely yielding zero rows.
--              Consolidated into exactly one executable statement via CTEs.
-- Purpose    : Discovers actual top-level keys populated by the AI diagnostic service
--              and reports key frequency alongside overall AI payload coverage metrics.
-- ---------------------------------------------------------------------
WITH DiscoveredKeys AS (
    SELECT
        k.key_name AS "discoveredKey",
        COUNT(*) AS "occurrenceCount"
    FROM "ExtensionDebugSession" eds
    CROSS JOIN LATERAL jsonb_object_keys(
        CASE
            WHEN eds."aiExplanation" IS NOT NULL
             AND jsonb_typeof(eds."aiExplanation") = 'object'
            THEN eds."aiExplanation"
            ELSE '{}'::jsonb
        END
    ) AS k(key_name)
    WHERE eds."analysisSource" = 'ai'
    GROUP BY k.key_name
),
AiSessionOverview AS (
    SELECT
        COUNT(*) AS "totalAiSessions",
        COUNT(eds."aiExplanation") AS "sessionsWithPayload",
        COUNT(*) FILTER (
            WHERE eds."aiExplanation" IS NOT NULL
              AND jsonb_typeof(eds."aiExplanation") = 'object'
        ) AS "validJsonObjectCount"
    FROM "ExtensionDebugSession" eds
    WHERE eds."analysisSource" = 'ai'
)
SELECT
    dk."discoveredKey",
    dk."occurrenceCount",
    ov."totalAiSessions",
    ov."sessionsWithPayload",
    ov."validJsonObjectCount",
    ROUND(
        100.0 * dk."occurrenceCount" / NULLIF(ov."validJsonObjectCount", 0),
        2
    ) AS "keyOccurrencePercentage"
FROM AiSessionOverview ov
LEFT JOIN DiscoveredKeys dk ON TRUE
ORDER BY dk."occurrenceCount" DESC NULLS LAST, dk."discoveredKey" ASC;


-- ---------------------------------------------------------------------
-- QUERY 10: Progress Counter Integrity & State Drift Audit
-- Category   : Data Integrity Verification & Constraint Alignment
-- Concepts   : CTE pre-aggregation, outer joins, FILTER clauses, multi-case discrepancy logic
-- Schema Note: UserProgress has a table CHECK constraint:
--              ("totalSubmissions" = "successfulSubmissions" + "failedSubmissions").
--              Interpreting "totalSubmissions" as completed/evaluated submissions is
--              inferred from this mathematical constraint, rather than application code.
--              Submissions without a SubmissionResult (sr."id" IS NULL) are pending or in-flight,
--              so they are reported as "pendingSubmissions" and NOT flagged as data drift.
-- Purpose    : Audits cached UserProgress counter columns against calculated raw
--              transactional records, preventing JOIN fan-out duplication.
-- ---------------------------------------------------------------------
WITH UserSubmissionStats AS (
    SELECT
        s."userId",
        COUNT(s."id") AS "rawTotalSubmissions",
        COUNT(sr."id") AS "calculatedCompletedSubmissions",
        COUNT(sr."id") FILTER (WHERE sr."status" = 'success') AS "calculatedSuccessful",
        COUNT(sr."id") FILTER (WHERE sr."status" = 'error') AS "calculatedFailed",
        COUNT(s."id") FILTER (WHERE sr."id" IS NULL) AS "pendingOrUnfinishedSubmissions"
    FROM "Submission" s
    LEFT JOIN "SubmissionResult" sr ON sr."submissionId" = s."id"
    GROUP BY s."userId"
)
SELECT
    u."id" AS "userId",
    u."name" AS "userName",
    u."email" AS "userEmail",
    -- Submission counts
    COALESCE(stats."rawTotalSubmissions", 0) AS "rawTotalSubmissions",
    COALESCE(stats."pendingOrUnfinishedSubmissions", 0) AS "pendingSubmissions",
    -- Completed progress audit (matching UserProgress_counts_check constraint)
    COALESCE(up."totalSubmissions", 0) AS "cachedCompletedSubmissions",
    COALESCE(stats."calculatedCompletedSubmissions", 0) AS "calculatedCompletedSubmissions",
    COALESCE(up."successfulSubmissions", 0) AS "cachedSuccessful",
    COALESCE(stats."calculatedSuccessful", 0) AS "calculatedSuccessful",
    COALESCE(up."failedSubmissions", 0) AS "cachedFailed",
    COALESCE(stats."calculatedFailed", 0) AS "calculatedFailed",
    -- State drift classification
    CASE
        WHEN up."id" IS NULL THEN 'MISSING_PROGRESS_RECORD'
        WHEN up."successfulSubmissions" <> COALESCE(stats."calculatedSuccessful", 0)
          OR up."failedSubmissions" <> COALESCE(stats."calculatedFailed", 0)
          OR up."totalSubmissions" <> COALESCE(stats."calculatedCompletedSubmissions", 0)
        THEN 'DISCREPANCY_DETECTED'
        ELSE 'CONSISTENT'
    END AS "auditStatus"
FROM "User" u
LEFT JOIN "UserProgress" up ON up."userId" = u."id"
LEFT JOIN UserSubmissionStats stats ON stats."userId" = u."id"
ORDER BY u."id" ASC;
