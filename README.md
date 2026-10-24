# summarize-work.sh

Turns git history into a plain-English list of work completed during a date range. It reads
**commits**, **merges** (pull requests / merge requests) and **release tags** and writes each one
as a short past-tense sentence, grouped by kind of work.

```
# Work completed: Oct 20 – Oct 24, 2026

## my-app

### Releases
- Released v1.1.0 on Oct 24 ("Dark mode release"), which included 18 changes since v1.0.0.

### New features
- Auth: Added password reset flow.
- Added dark mode for the dashboard (#150).

### Bug fixes
- Fixed null totals (PROJ-91).
- Made sure we don't send emails to unsubscribed users.

### Maintenance
- Updated 4 dependencies, including lodash, axios and react (plus 1 other).

_Altogether that's 18 commits, 2 merges and 1 release._
```

The sentences come from fixed rules and explicitly 
 not an AI or LLM. Nothing is sent over the network to allow for resilience
(unless you ask for `--fetch`), and the same history always gives the same output.

## Requirements

- `git`
- `bash` 3.2 or newer (the version that ships with macOS is fine). You can still start the script with `sh`; see [Setup](#setup).
- Standard `awk`, `sort`, `date` and `find`. Both the macOS/BSD and Linux/GNU versions work.

## Setup

```sh
chmod +x summarize-work.sh
```

You can also copy or link it somewhere on your `PATH`, for example
`ln -s "$PWD/summarize-work.sh" /usr/local/bin/summarize-work`.

You can start it whichever way you like. These all do the same thing:

```sh
./summarize-work.sh --yesterday
bash summarize-work.sh --yesterday
sh summarize-work.sh --yesterday
```

The script is written for bash. If you start it with `sh`, `zsh` or another shell, it
re-runs itself under `bash` automatically, so `bash` needs to be installed (it is on macOS
and nearly every Linux system).

## Usage

```
summarize-work.sh [options] [START [END]]
```

Run it from inside a git repository, or point it at one or more repos with `--repo` or `--scan`.

### Choosing the date range

Dates can be written as `YYYY-MM-DD`, `MM/DD/YYYY`, `MM/DD/YY`, `today` or `yesterday`.
Both ends of the range are included, so each day counts from 00:00:00 to 23:59:59.

| Command                                | Range                                  |
| -------------------------------------- | -------------------------------------- |
| `summarize-work.sh 10/20/2026 10/24/2026` | Oct 20 through Oct 24                |
| `summarize-work.sh 2026-10-23`         | That single day                        |
| `summarize-work.sh`                    | This week, Monday through today (default) |
| `summarize-work.sh --today`            | Today                                  |
| `summarize-work.sh --yesterday`        | Yesterday                              |
| `summarize-work.sh --this-week`        | Monday of this week through today      |
| `summarize-work.sh --last-week`        | Monday through Sunday of last week     |
| `summarize-work.sh --days 3`           | The last 3 days, including today       |

### Choosing what to include

| Option              | What it does |
| ------------------- | ------------ |
| `-r, --repo PATH`   | Summarize this repository. You can repeat it. Defaults to the repo you're in. |
| `-s, --scan DIR`    | Summarize every git repo found under `DIR` (up to 3 levels deep, skipping `node_modules`). Repos with no activity are left out. |
| `-b, --branch REF`  | Only follow this branch or ref. You can repeat it. By default it reads all local **and** remote-tracking branches. |
| `-a, --author TEXT` | Only include work whose author name or email matches `TEXT`. You can repeat it, and matching any one counts. |
| `-m, --me`          | Only include your own work, using `git config user.email` in each repo. |
| `-f, --fetch`       | Run `git fetch --all --tags` in each repo first, so remote work is up to date. |
| `--no-tags`         | Leave releases out. |
| `--all-commits`     | Also list each commit inside a merged pull request (see [Merges](#merges)). |

> **Heads up:** with no author filter, the report covers **everyone's** work on every branch.
> Use `--me` for a personal status report.

### Output options

| Option              | What it does |
| ------------------- | ------------ |
| `-o, --output FILE` | Write to `FILE` instead of the terminal. |
| `--format FMT`      | `markdown` (default), `text` (plain text with `•` bullets) or `slack` (Slack-style `*bold*` / `_italic_`). |
| `--dates`           | Add the date to each bullet, e.g. `Fixed null totals (PROJ-91) — Oct 23`. |
| `--no-totals`       | Leave out the closing "Altogether that's…" line. |
| `-h, --help`        | Show the built-in help. |

### Where the output goes

By default the summary is printed to the terminal (stdout). Nothing is saved unless you ask.

To save it to a file, use `-o` / `--output`. The summary then goes **only** to that file, not
the terminal, and an existing file at that path is overwritten:

```sh
./summarize-work.sh --yesterday -o ~/reports/yesterday.md
```

Since it's ordinary stdout, you can also redirect or pipe it yourself:

```sh
./summarize-work.sh --this-week > week.md          # save to a file
./summarize-work.sh --this-week | pbcopy           # copy to the clipboard (macOS)
./summarize-work.sh --this-week | tee week.md      # print and save at once
```

Errors and warnings go to stderr, so they never end up in the saved summary.

### Examples

```sh
# The week of Oct 20, for the repo you're in
./summarize-work.sh 10/20/2026 10/24/2026

# My work yesterday, ready to paste into a stand-up channel
./summarize-work.sh --me --yesterday --format slack

# Every project under ~/code for last week, saved to a file
./summarize-work.sh --scan ~/code --last-week --me -o ~/reports/last-week.md

# Only what landed on main, with the latest from the remote
./summarize-work.sh --fetch --branch origin/main --this-week
```

## Running it on a schedule

Add an entry with `crontab -e`. For example, every Friday at 5 pm:

```cron
0 17 * * 5  /path/to/summarize-work.sh --me --scan ~/code -o ~/reports/week-$(date +\%F).md
```

Or every weekday at 6 pm for a daily log:

```cron
0 18 * * 1-5  /path/to/summarize-work.sh --me --today --scan ~/code -o ~/reports/day-$(date +\%F).md
```

In a crontab, `%` has to be written as `\%`. Cron also runs with a minimal `PATH`, so use
absolute paths for the script and the folders.

## How it works

For each repository, the script does the following:

1. **Collects** the raw history for the date range with `git log` (commits and merges, filtered by
   committer date) and `git for-each-ref` (tags, filtered by creation date).
2. **Sorts** everything into date order.
3. **Rewrites** each item as a sentence and **sorts it into a section** using the rules below.
4. **Prints** the sections in a fixed order: Releases, New features, Bug fixes, Improvements,
   Documentation, Testing, Maintenance, Other work. Empty sections are skipped.

### Turning a commit message into a sentence

The rules are applied in this order:

1. **Clean up.** Removes `[skip ci]`-style tags and gitmoji shortcodes like `:sparkles:`.
2. **Pull out references.** A trailing `(#123)` (from squash merges) and a leading ticket ID such
   as `PROJ-88:` or `[PROJ-88]` are moved to the end of the sentence: `(#123, PROJ-88)`.
3. **Read conventional-commit prefixes.** `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`
   and the others pick the section. A scope becomes a label, so `fix(auth): …` turns into
   `Auth: Fixed …`. Scopes of 3 letters or fewer are written in capitals, so `api` becomes `API`.
   A `!` (as in `feat!:`) adds `(breaking change)`. The `pkg: message` style without a type is
   treated as a scope too.
4. **Change the verb to past tense.** The first word is matched against a list of about 150 common
   commit verbs in any form, so `Add`, `Adds`, `Adding` and `Added` all become **Added**. Irregular
   verbs (`build` → built, `run` → ran) and doubled consonants (`drop` → dropped) are handled. A
   word ending in "s" followed by *to/for/in/of…* is treated as a noun, so "Updates to the README"
   isn't misread as a verb.
5. **Fall back when there's no verb.** If the section is known, a suitable verb is added in front
   (a `feat:` message gets "Added", a `fix:` message gets "Fixed", and so on). Otherwise the
   sentence starts with "Worked on …".
6. **Handle special cases:**
   - `Revert "X"` → `Rolled back the earlier change "X"`
   - `Don't X` → `Made sure we don't X`
   - `Initial commit` → `Set up the initial project`
   - `Support X` → `Added support for X`
   - `cleanup` / `setup` → `Cleaned up` / `Set up`

#### Choosing the section

The first rule that applies wins:

1. The conventional-commit type (`feat:` → New features, `fix:` → Bug fixes, …)
2. The merged branch's prefix (`feature/`, `fix/`, `docs/`, `chore/`, `refactor/`, `test/`)
3. Keywords: README, docs, changelog → Documentation; tests, specs, coverage → Testing
4. The verb itself. For example, *fix / resolve / prevent* → Bug fixes; *add / implement / support*
   → New features; *update / refactor / remove* → Improvements; *bump / upgrade / lint / deploy*
   → Maintenance
5. Otherwise → Other work

### Merges

Supported merge message styles:

| Host         | Merge message                                   | Text used for the sentence             |
| ------------ | ----------------------------------------------- | -------------------------------------- |
| GitHub       | `Merge pull request #150 from org/feature/x`    | The PR title (first line of the body)  |
| GitLab       | `Merge branch 'x' into 'main'` + `See merge request …!12` | The MR title, cited as `!12`  |
| Azure DevOps | `Merged PR 42: Title`                           | The title                              |
| Bitbucket    | `Merged in feature/x (pull request #7)`         | The branch name                        |
| Plain git    | `Merge branch 'feature/x' into main`            | The branch name                        |

If a merge has no title, the branch name is turned into words. For example,
`fix/PROJ-91-null-totals` becomes "Fixed null totals (PROJ-91)": the `fix/` prefix sets the
section and the ticket ID is moved to the end.

**Commits inside a merged PR are not listed separately.** The PR is the item that got done; its
work-in-progress commits are just how it got there. The script uses
`git rev-list <parent1>..<parent2>` to find each merge's commits and leaves them out. To list
them anyway, use `--all-commits`.

**Housekeeping merges are skipped.** These include `Merge branch 'main' into my-feature`,
`Merge remote-tracking branch …`, `Merge branch 'x' of github.com:…` (from `git pull`),
`Merge tag …`, and PRs whose source branch is main, master or develop.

### Releases

Every tag created in the date range becomes a line like:

> Released v1.1.0 on Oct 24 ("Dark mode release"), which included 18 changes since v1.0.0.

The quoted text is the annotated tag's message, and is left out for lightweight tags. The change
count is the number of non-merge commits since the previous tag (found with `git describe`).
Releases are not filtered by `--author`.

### Noise filtering and tidying

- **Skipped:** commits starting with `wip`, `fixup!`, `squash!`, `amend!`, `tmp`, `temp`,
  or `test commit`, and messages made only of punctuation.
- **Dependency bumps** (`Bump lodash from 4.17.20 to 4.17.21`, as Dependabot writes them) are
  listed one by one when there are up to three. With more, they're combined into one line:
  "Updated 7 dependencies, including …".
- **Duplicates** are removed, such as the same commit cherry-picked onto two branches.
- **Totals.** The closing totals line counts every non-merge commit in the range, including the
  ones inside merged PRs that aren't listed.

## Limitations and tips

- **The output is only as good as the commit messages.** "stuff" becomes "Worked on stuff."
  Conventional commits (`feat:`, `fix:`) and good PR titles give the best results.
- **Commits are dated by when they were committed, not when they were written.** After a rebase,
  older work shows up on the day it was rebased.
- **Remote branches are only as fresh as your last fetch.** Use `--fetch` (or run `git fetch`
  yourself) for up-to-date results.
- **Unmerged branches are included by default.** Commits on feature branches that haven't been
  merged yet still appear as work. Use `--branch origin/main` to report only what's been merged.
- **Changing the rules.** To teach it a new verb, add the word to the right `VERBS[...]` list in
  the script. Irregular past tenses go in the `IRR` list, as `base:past`.
