---
description: Create a new project workspace for a development task
argument-hint: [description]
---

# New Project Workspace

You are helping a developer create a new project workspace. Projects live
under the `projects/` directory and provide structured working environments
for specific tasks (bug investigations, feature development, CI work, etc.).

Everything after "new" in `$ARGUMENTS` is an optional initial description
of the task.

## Step 1: Gather Task Information

Ask the user questions to understand what they're working on. Use the
AskUserQuestion tool for structured questions and encourage free-text
descriptions.

**1a. Task Description**

If the user provided a description after "new" in the arguments, use that.
Otherwise, ask:

> "What task are you working on? Please describe it in a sentence or two."

**1b. Task Type**

Based on the description, suggest a task type and confirm with the user.
Use AskUserQuestion with these options:

| Type | When to suggest |
|------|-----------------|
| Bug investigation | Description mentions a bug, issue, ticket, regression, failure, broken behavior |
| Feature development | Description mentions adding, implementing, creating new functionality |
| CI/testing | Description mentions CI, test failures, pipeline configuration |
| Documentation | Description mentions docs, writing, documenting, guide |
| Analysis/review | Description mentions reviewing, analyzing, investigating (without a specific bug), understanding |

**1c. Tracker Ticket (optional)**

Check the active preset's `tracker:` block in `presets/<active-preset>/preset.yaml`
(read `preset.name` from `dev-env.yaml`). If no preset or `type: none`,
skip this question entirely and proceed to 1d.

If `type: jira | github | gitlab`, ask:
> "Do you have a ticket for this task? If so, paste the URL
> (e.g., `<tracker.base_url>/PROJECT-123`). Otherwise, say 'no'."

**1d. Related Repositories**

Ask which repos from this workspace are relevant. **Dynamically load
the repo list** from `dev-env.yaml` at the workspace root:

1. Read `dev-env.yaml` and extract each repo's `name` and `summary`
   fields from the `repos:` array. Also extract the top-level
   `preset:` field if present (e.g., `preset: tnf`).
2. Build AskUserQuestion options with multiSelect=true, using
   `name` as the label and `summary` as the description.
3. If `dev-env.yaml` does not exist or has no repos, skip this step
   and note that no repos are configured (the user can add them
   later by editing the project's CLAUDE.md frontmatter).

**1e. Worktree Setup**

If the project type is `feature`, `bug`, or `docs`, and repos were
selected in Step 1d:

1. Ask which repos the user plans to **modify** (vs. reference-only).
   Use AskUserQuestion with multiSelect=true, listing the repos
   selected in Step 1d:

   > "Which of these repos will you be making changes to? (The others
   > will be available for reference but won't get a worktree.)"

   If only one repo was selected in 1d, skip this question and assume
   it will be modified.

2. Derive the branch name:
   - If a ticket URL was provided, extract the ticket ID using the
     active preset's `tracker.ticket_regex` (e.g., `OCPEDGE-2608`
     from `https://issues.redhat.com/browse/OCPEDGE-2608`), then ask:
     > "Branch name will start with `<ticket-id-lowercase>`. Add a short slug?
     > (e.g., `multi-hypervisor` → `ocpedge-2608-multi-hypervisor`)"
   - If no ticket, use the project folder name as the branch name
   - For `bug` type, prefix with `fix/`
   - Confirm the final branch name with the user

3. For each repo the user plans to modify, create a worktree:

   ```bash
   # Ensure .worktrees/ is excluded from git tracking
   grep -qF '.worktrees' repos/<repo>/.git/info/exclude 2>/dev/null \
     || echo '.worktrees/' >> repos/<repo>/.git/info/exclude

   # Determine the default branch (main or master)
   default_branch=$(git -C repos/<repo> symbolic-ref refs/remotes/origin/HEAD \
     2>/dev/null | sed 's|refs/remotes/origin/||')
   if [ -z "$default_branch" ]; then
     for candidate in main master; do
       if git -C repos/<repo> rev-parse --verify "origin/$candidate" \
         >/dev/null 2>&1; then
         default_branch="$candidate"; break
       fi
     done
   fi

   # Create the worktree
   git -C repos/<repo> worktree add \
     .worktrees/<branch> -b <branch> origin/$default_branch
   ```

4. Store the branch name and worktree repos for Step 3b (frontmatter).

For `ci-testing` and `analysis`: do NOT create worktrees in this step.
Worktrees for these types are handled in Step 1f (analysis-PR) or
created manually later if needed.

**1f. Additional Context (optional)**

Ask: "Any additional context? (PR URLs, CI job URLs, related projects,
etc.) Say 'no' to skip."

**If the project type is `analysis` and the user provided a PR URL:**

Extract the repo and PR number, then create a worktree:

1. Parse repo from URL (e.g., `cluster-etcd-operator` from
   `https://github.com/openshift/cluster-etcd-operator/pull/1620`)
2. Fetch and create a worktree for the PR:

   ```bash
   grep -qF '.worktrees' repos/<repo>/.git/info/exclude 2>/dev/null \
     || echo '.worktrees/' >> repos/<repo>/.git/info/exclude
   git -C repos/<repo> fetch origin pull/<number>/head:pr/<number>
   git -C repos/<repo> worktree add .worktrees/pr/<number> pr/<number>
   ```

3. Store `branch: pr/<number>` and the repo in worktrees list.
4. Add the PR URL to `related_links:` in frontmatter.

## Step 2: Generate Folder Name

Based on the gathered information:

1. If a tracker ticket was provided, extract the ticket ID using the
   preset's `tracker.ticket_regex` and use it as the suggested folder name.
2. Otherwise, generate a kebab-case slug from the task description
   (e.g., "Fix kubelet start timeout after fencing" becomes
   `fix-kubelet-start-timeout`). Keep it under 40 characters.
3. **Check if `projects/<suggestion>/` already exists** using ls. If it
   does, inform the user and ask:
   - Use a different name (suggest appending `-2`, `-3`, etc.)
   - Resume the existing project instead (point them to `/project:resume`)
4. Once you have a name that doesn't conflict, present the suggestion
   and ask the user to confirm or provide an alternative:

> "I suggest naming the project folder: `<suggestion>`. Is that OK, or
> would you prefer a different name?"

## Step 3: Create Project Scaffold

Create the project directory and generate files based on the task type.

**3a. Create directory structure**

Use the Bash tool to create directories. The base is always
`projects/<folder-name>/`.

Additional subdirectories by type:

| Type | Directories |
|------|-------------|
| Bug investigation | `logs/`, `docs/` |
| Feature development | `docs/`, `patches/` |
| CI/testing | `results/`, `scripts/` |
| Documentation | `drafts/` |
| Analysis/review | `docs/` |

**3b. Generate CLAUDE.md (lean index)**

Write a **lean index** CLAUDE.md (~50-80 lines) at
`projects/<folder-name>/CLAUDE.md` using the Write tool. This file is
an index, not a document — it orients Claude on what the project is and
where to look. All detailed content goes into separate files (Step 3d).

The content MUST follow the lean template for the detected type
(see [CLAUDE.md Templates](#claudemd-templates) below).

**3c. Generate .gitignore**

Write a `.gitignore` at `projects/<folder-name>/.gitignore` with:

```
# Large files that shouldn't be committed
*.log
*.txt.gz
*.tar.gz
```

**3d. Create starter detail files**

Create type-specific starter files alongside CLAUDE.md. Use the Write
tool for each file. Every file created MUST have a corresponding row in
the CLAUDE.md Reference Files table (generated in Step 3b).

| Type | Starter files |
|------|--------------|
| Bug investigation | `investigation.md`, `ci-runs.md`, `source-code-map.md` |
| Feature development | `design.md`, `source-code-map.md` |
| CI/testing | `ci-runs.md`, `test-failures.md` |
| Documentation | `drafts.md` |
| Analysis/review | `findings.md` |

Use the templates in the [Detail File Templates](#detail-file-templates)
section below for the starter content of each file.

## Step 4: Suggest Skills and Next Steps

After creating the project, provide a summary:

1. List the files and directories created
2. If worktrees were created, list them with their paths:
   > **Worktrees created:**
   > - `repos/<repo>/.worktrees/<branch>/` → branch `<branch>`
   >
   > When working on code changes, use the worktree paths above
   > instead of the main checkout (`repos/<repo>/`).
3. Suggest relevant skills based on the task type:

   Read the active preset's `skill_suggestions` from
   `presets/<active-preset>/preset.yaml`. Look up the list for the
   project's task type. If the preset has no `skill_suggestions` or no
   entry for this type, skip this step — do not invent skill names.

4. Suggest concrete next steps for starting the work
5. Remind the user they can resume this project later with
   `/project:resume`

---

## CLAUDE.md Templates

CLAUDE.md is an **index**, not a document. It has just enough to orient
Claude on what the project is and where to look. All detailed content
lives in separate files (created in Step 3d) that are loaded on demand
when resuming the project.

### Common Frontmatter

```yaml
---
project: <folder-name>
type: <bug|feature|ci-testing|docs|analysis>
created: <YYYY-MM-DD>
status: active
ticket: <URL or "none">
preset: <preset name from dev-env.yaml, or omit if none>
repos:
  - <repo1>
  - <repo2>
branch: <branch-name or omit if no worktrees>
worktrees:
  - <repo1>
# worktrees: subset of repos that have active worktrees (from Step 1e)
# branch: the branch name used for all worktrees
# Omit both if no worktrees were created (ci-testing, analysis non-PR)
related_links:
  - <any URLs provided>
# If user provided no URLs, use: related_links: []
---
```

### Template Structure

Every project CLAUDE.md follows this structure. The total file should
be ~50-80 lines. Generate using the common frontmatter above, then
these sections in order:

1. **`# <Title>`** — from JIRA ticket or user description

2. **`## <Type> Summary`** — heading varies by type (see below).
   Write a 2-3 sentence description of the task, then a short metadata
   bullet list (Jira link, Assignee if known). NO inline investigation
   details, timelines, or findings — those go in detail files.

3. **`## Reference Files`** — table with columns `| File | Content |`.
   One row per detail file created in Step 3d. This is the manifest —
   it is how future sessions discover detail files. During the project
   lifecycle, new detail files may be created organically (e.g.,
   `adversarial-reviews.md`, `jira-comment-root-cause.md`). When
   creating a new detail file, always add a row here.

4. **`## <Plan Section>`** — type-specific heading (see below) with
   a checklist of action items. Stays in CLAUDE.md because it is
   compact and action-oriented.

5. **`## Progress`** — high-level checklist starting with
   `- [x] Project created`, then type-specific milestone items
   (see below, all unchecked). Stays in CLAUDE.md because
   `/project:resume` reads it to suggest next steps.

### Type-Specific Content

For each type below, the specification defines:
- The summary heading name
- Metadata bullets to include in the summary
- Which detail files to create (→ rows in Reference Files table)
- The plan section heading and checklist items
- The progress checklist items

**Bug Investigation** (`type: bug`)
- Summary heading: `## Bug Summary`
- Metadata: Ticket, Assignee (TBD)
- Detail files: `investigation.md`, `ci-runs.md`, `source-code-map.md`
- Plan heading: `## Fix Plan`
- Plan items: Identify root cause, Determine fix approach, Implement
  fix, Test on cluster, Submit PR
- Progress: Bug details captured, Logs collected and analyzed,
  Root cause identified, Fix implemented, PR submitted

**Feature Development** (`type: feature`)
- Summary heading: `## Feature Summary`
- Metadata: Ticket, Target Version (TBD)
- Detail files: `design.md`, `source-code-map.md`
- Plan heading: `## Implementation Plan`
- Plan items: Review enhancement doc, Design approach, Implement
  changes, Write tests, Submit PRs
- Progress: Design documented, Implementation started, Tests written,
  PR(s) submitted, PR(s) merged

**CI/Testing** (`type: ci-testing`)
- Summary heading: `## Test Summary`
- Metadata: Ticket, CI Job(s) (TBD)
- Detail files: `ci-runs.md`, `test-failures.md`
- Plan heading: `## Test Plan`
- Plan items: Identify failing jobs, Analyze failures, Implement fixes,
  Validate CI passing
- Progress: CI jobs identified, Failures analyzed, Fixes implemented,
  CI passing

**Documentation** (`type: docs`)
- Summary heading: `## Doc Summary`
- Metadata: Ticket, Target (which docs are created/updated)
- Detail files: `drafts.md`
- Plan heading: `## Outline`
- Plan items: Research and outline, Write draft, Technical review,
  Editorial review, Submit PR
- Progress: Draft written, Technical review, Editorial review,
  PR submitted

**Analysis/Review** (`type: analysis`)
- Summary heading: `## Analysis Summary`
- Metadata: Ticket, Scope (what is being analyzed/reviewed)
- Detail files: `findings.md`
- Plan heading: `## Analysis Plan`
- Plan items: Define scope, Gather data, Analyze findings,
  Write recommendations
- Progress: Analysis started, Findings documented, Recommendations
  made, Actions taken

---

## Detail File Templates

Use these templates when creating starter detail files in Step 3d.
Each file should have a heading and minimal structure — enough to guide
where content goes, but not so much that it feels like boilerplate.

### `investigation.md` (bug)

```markdown
# Investigation

## Failure Analysis

_Describe the observed failure and symptoms._

## Root Cause

_Root cause goes here once identified._

## Proposed Fix

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
```

### `ci-runs.md` (bug, ci-testing)

```markdown
# CI Runs

<!-- Add a section per CI run analyzed. Template: -->
<!-- ## Run <ID> (<short description>)              -->
<!--                                                -->
<!-- **Job:** `<job name>`                           -->
<!-- **Date:** <YYYY-MM-DD>                          -->
<!--                                                -->
<!-- | Artifact | Description |                     -->
<!-- |----------|-------------|                      -->
<!--                                                -->
<!-- **Timeline:**                                   -->
<!-- ```                                             -->
<!-- <chronological events>                          -->
<!-- ```                                             -->
```

### `source-code-map.md` (bug, feature)

```markdown
# Source Code Map

| Repo | Key Path | Purpose |
|------|----------|---------|
```

When populating this file:
- For each selected repo, check `repos/<repo>/CLAUDE.md` or
  `presets/*/context/<repo>.md` for "Key paths", "Key files",
  or similar sections.
- If found, add 1-3 most relevant paths to the table.
- If not found, add the repo name with an empty path and a TODO
  comment like "TODO: fill in relevant paths".

### `design.md` (feature)

```markdown
# Design

## Architecture

_High-level design and component interactions._

## API Changes

_New or modified APIs._

## Related PRs

| PR | Repo | Status | Description |
|----|------|--------|-------------|
```

### `test-failures.md` (ci-testing)

```markdown
# Test Failures

| Test | Error | Root Cause | Fix | Status |
|------|-------|------------|-----|--------|
```

### `drafts.md` (docs)

```markdown
# Drafts

## Target Documents

| Document | Path | Status |
|----------|------|--------|

## Outline

_Document outline goes here._

## Review Notes

_Technical and editorial review feedback._
```

### `findings.md` (analysis)

```markdown
# Findings

## Scope

_What is being analyzed and why._

## Findings

_Analysis results._

## Recommendations

| # | Recommendation | Priority | Status |
|---|----------------|----------|--------|
```

---

## Important Notes

- Always use the Write tool to create files, never echo/cat via Bash
- Use Bash tool only for `mkdir -p` to create directories
- After creating the project, briefly list what was created and what
  the user should do next
- If the user provides enough context in the initial `/project:new`
  arguments, minimize questions — only ask what's truly missing
- The YAML frontmatter `status` field should always start as `active`
- Use today's date for the `created` field
