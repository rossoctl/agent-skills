#!/usr/bin/env python3
"""Epic Tracker — Fetch in-progress epics across a GitHub org with activity data.

Queries issues labeled 'epic' across all org repos, optionally enriches with
GitHub Projects v2 Status field, and cross-references PR/issue activity for
the reporting period.

Output: JSON to stdout with the structure:
{
  "epics": [...],
  "fallback_mode": false,
  "period": {"since": "...", "until": "..."}
}
"""
import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta


def run_gh(args, timeout=60):
    cmd = ['gh'] + args
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if result.returncode != 0:
            print(f"Warning: gh command failed: {' '.join(cmd)}\n  {result.stderr.strip()}", file=sys.stderr)
            return None
        return json.loads(result.stdout) if result.stdout.strip() else None
    except subprocess.TimeoutExpired:
        print(f"Warning: gh command timed out: {' '.join(cmd)}", file=sys.stderr)
        return None
    except json.JSONDecodeError:
        return None


def get_org_repos(org):
    repos = run_gh(['repo', 'list', org, '--limit', '100', '--json', 'name'])
    return [r['name'] for r in (repos or [])]


def get_epics(org, repos):
    epics = []
    for repo in repos:
        issues = run_gh([
            'issue', 'list', '-R', f'{org}/{repo}',
            '--label', 'epic', '--state', 'open',
            '--limit', '100',
            '--json', 'number,title,assignees,labels,body,url,updatedAt'
        ])
        if not issues:
            continue
        for issue in issues:
            issue['repo'] = repo
            issue['org'] = org
            epics.append(issue)
    return epics


def extract_key_result(body):
    if not body:
        return ""
    for pattern in [r'##\s*Key Results?\s*\n', r'##\s*OKR\s*\n']:
        match = re.search(pattern, body, re.IGNORECASE)
        if match:
            rest = body[match.end():]
            lines = rest.split('\n')
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                if line.startswith('#'):
                    break
                cleaned = re.sub(r'^[-*]\s*', '', line)
                cleaned = re.sub(r'^\[.\]\s*', '', cleaned)
                if cleaned:
                    return cleaned[:120]
    return ""


def get_activity_via_timeline(org, repo, epic_number, since, until):
    """Count cross-referenced closed PRs whose reference falls within the window.

    The timeline 'cross-referenced' event carries its own created_at (when the
    reference was made). Filtering on it bounds activity to the reporting window
    instead of counting every cross-reference over the epic's lifetime. The
    window is [since, until] inclusive (date-only comparison, ISO timestamps
    sort lexically).
    """
    # until is a date (YYYY-MM-DD); make the upper bound inclusive of that day.
    until_end = f"{until}T23:59:59Z"
    jq_filter = (
        '.[] '
        '| select(.event == "cross-referenced") '
        '| select(.source.issue.pull_request != null) '
        '| select(.source.issue.state == "closed") '
        f'| select(.created_at >= "{since}" and .created_at <= "{until_end}") '
        '| .source.issue.number'
    )
    try:
        result = subprocess.run(
            ['gh', 'api', f'repos/{org}/{repo}/issues/{epic_number}/timeline',
             '--paginate', '--jq', jq_filter],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            return {'prs_merged': 0, 'issues_closed': 0, 'pr_numbers': []}
        # A PR can be cross-referenced more than once; dedupe.
        numbers = sorted({int(n) for n in result.stdout.strip().split('\n') if n.strip()})
        return {
            'prs_merged': len(numbers),
            'issues_closed': 0,
            'pr_numbers': numbers,
        }
    except (subprocess.TimeoutExpired, ValueError):
        return {'prs_merged': 0, 'issues_closed': 0, 'pr_numbers': []}


def get_sub_issue_activity(org, repo, epic_number, since, until):
    """Count an epic's sub-issues that are open or were closed in the window.

    This is the PRIMARY activity signal: teams often park active epics in an
    "Epics" board column rather than "In Progress", making board Status an
    unreliable gate. Sub-issues come from the plain REST sub_issues endpoint,
    which needs no read:project scope. An epic is "active" if it has any open
    sub-issue (backlog / in-progress) or any sub-issue closed within
    [since, until] inclusive.

    Fetches the sub_issues endpoint once (a single --paginate call) projecting
    only the three fields we need into one compact object per line, then filters
    locally. Projecting server-side keeps us safe from control chars in raw
    sub-issue bodies (which break client-side json parsing) while avoiding the
    4x API cost — and mid-run snapshot skew — of separate calls per metric.
    Returns {open, closed_recent, closed_recent_numbers, latest_closed_at, total}.
    latest_closed_at is the most recent in-window closure timestamp ("" if none)
    — used for recency-based ranking so a single bulk-close epic does not crowd
    out low-volume but freshly-active epics.
    """
    until_end = f"{until}T23:59:59Z"
    since_start = f"{since}T00:00:00Z"
    empty = {'open': 0, 'closed_recent': 0, 'closed_recent_numbers': [],
             'latest_closed_at': '', 'total': 0}
    try:
        result = subprocess.run(
            ['gh', 'api', f'repos/{org}/{repo}/issues/{epic_number}/sub_issues',
             '--paginate', '--jq', '.[] | {number, state, closed_at}'],
            capture_output=True, text=True, timeout=20
        )
        if result.returncode != 0:
            return empty

        # One compact JSON object per line (NDJSON across all pages).
        rows = []
        for line in result.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue

        # closed_at is an ISO-8601 UTC timestamp (fixed-width, Z-suffixed), so a
        # plain string range check is a correct in-window test. A null/missing
        # closed_at ("") is lexically below since_start and thus excluded.
        def closed_in_window(row):
            if row.get('state') != 'closed':
                return False
            ts = row.get('closed_at') or ''
            return since_start <= ts <= until_end

        open_count = sum(1 for r in rows if r.get('state') == 'open')
        closed_numbers = sorted({r['number'] for r in rows if closed_in_window(r)})
        latest = max((r['closed_at'] for r in rows if closed_in_window(r)), default='')
        return {
            'open': open_count,
            'closed_recent': len(closed_numbers),
            'closed_recent_numbers': closed_numbers,
            'latest_closed_at': latest,
            'total': len(rows),
        }
    except (subprocess.TimeoutExpired, ValueError):
        return empty


PROJECT_NUMBER = 8  # "Kagenti Issue Prioritization" — the board clawgenti can access


def query_projects_v2_status(org, project_number=PROJECT_NUMBER):
    """Query a specific GitHub Projects v2 board for issue statuses.

    Returns {issue_url: status} map, or None on failure.
    """
    query = """
    query($org: String!, $num: Int!) {
      organization(login: $org) {
        projectV2(number: $num) {
          title
          items(first: 100) {
            nodes {
              content {
                ... on Issue {
                  url
                  number
                  repository { name }
                }
              }
              fieldValues(first: 10) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    field { ... on ProjectV2SingleSelectField { name } }
                  }
                }
              }
            }
          }
        }
      }
    }
    """
    result = subprocess.run(
        ['gh', 'api', 'graphql',
         '-F', f'org={org}', '-F', f'num={project_number}',
         '-f', f'query={query}'],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        return None

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None

    project = data.get('data', {}).get('organization', {}).get('projectV2')
    if not project:
        return None

    status_map = {}
    for item in project.get('items', {}).get('nodes', []):
        content = item.get('content')
        if not content or 'url' not in content:
            continue
        url = content['url']
        for fv in item.get('fieldValues', {}).get('nodes', []):
            field = fv.get('field', {})
            if field.get('name', '').lower() == 'status':
                status_map[url] = fv.get('name', '')
    return status_map


def main():
    p = argparse.ArgumentParser(description='Fetch active epics across a GitHub org')
    p.add_argument('--org', required=True, help='GitHub organization')
    p.add_argument('--since', help='Start of reporting period (YYYY-MM-DD)')
    p.add_argument('--until', help='End of reporting period (YYYY-MM-DD)')
    p.add_argument('--max-epics', type=int, default=10, help='Maximum epics to include')
    p.add_argument('--skip-projects', action='store_true', help='Skip GitHub Projects v2 query')
    args = p.parse_args()

    since = args.since or (datetime.now() - timedelta(days=7)).strftime('%Y-%m-%d')
    until = args.until or datetime.now().strftime('%Y-%m-%d')

    print(f"Fetching repos for {args.org}...", file=sys.stderr)
    repos = get_org_repos(args.org)
    if not repos:
        print("Error: no repos found", file=sys.stderr)
        json.dump({'epics': [], 'fallback_mode': True, 'period': {'since': since, 'until': until}}, sys.stdout, indent=2)
        sys.exit(0)

    print(f"Scanning {len(repos)} repos for epics...", file=sys.stderr)
    epics = get_epics(args.org, repos)
    print(f"Found {len(epics)} open epics", file=sys.stderr)

    status_map = None
    fallback_mode = False
    if not args.skip_projects:
        print("Querying GitHub Projects v2 for status...", file=sys.stderr)
        status_map = query_projects_v2_status(args.org)
        if status_map is None:
            print("Warning: Projects v2 query failed (missing read:project scope?). Falling back to activity-based detection.", file=sys.stderr)
            fallback_mode = True
        else:
            print(f"Got status for {len(status_map)} project items", file=sys.stderr)
    else:
        fallback_mode = True

    results = []
    for epic in epics:
        url = epic.get('url', '')
        assignees = [a.get('login', '') for a in (epic.get('assignees') or []) if a.get('login')]
        lead = assignees[0] if assignees else ""
        labels = [l.get('name', '') for l in (epic.get('labels') or [])]
        key_result = extract_key_result(epic.get('body', ''))
        updated_at = (epic.get('updatedAt') or '')[:10]

        board_status = ""
        if status_map and url in status_map:
            board_status = status_map[url]

        # Primary signal: sub-issue activity (no read:project scope needed).
        sub = get_sub_issue_activity(args.org, epic['repo'], epic['number'], since, until)
        activity = get_activity_via_timeline(args.org, epic['repo'], epic['number'], since, until)

        # An epic is active if it has open sub-issues (backlog / in-progress),
        # a sub-issue closed this window, or a merged-PR cross-reference this
        # window. Board Status is display-only enrichment — never a gate.
        is_active = sub['open'] > 0 or sub['closed_recent'] > 0 or activity['prs_merged'] > 0
        if not is_active:
            continue

        # Prefer the board's own label when present; otherwise derive from
        # sub-issue state so the status column is still meaningful.
        if board_status:
            status = board_status
        elif sub['closed_recent'] > 0:
            status = "Active"
        elif sub['open'] > 0:
            status = "In progress"
        else:
            status = "Updated"

        results.append({
            'number': epic['number'],
            'repo': epic['repo'],
            'org': epic['org'],
            'title': epic['title'],
            'url': url,
            'lead': lead,
            'assignees': assignees,
            'status': status,
            'key_result': key_result,
            'activity_this_week': activity,
            'sub_issues': sub,
            'updated_at': updated_at,
            'labels': labels,
        })

    # Rank by RECENCY, not volume: any epic with a sub-issue closed this window
    # ranks above those with none (by freshest closure), so a single bulk-close
    # epic cannot crowd out low-volume but freshly-active epics. Among epics with
    # no recent closure, those with open sub-issues rank next, then by update.
    results.sort(key=lambda e: (
        1 if e['sub_issues']['latest_closed_at'] else 0,
        e['sub_issues']['latest_closed_at'],
        1 if e['sub_issues']['open'] else 0,
        e['activity_this_week']['prs_merged'],
        e['updated_at'],
    ), reverse=True)
    results = results[:args.max_epics]

    output = {
        'epics': results,
        'fallback_mode': fallback_mode,
        'period': {'since': since, 'until': until},
    }
    json.dump(output, sys.stdout, indent=2)
    print("", file=sys.stdout)
    print(f"Output: {len(results)} active epics", file=sys.stderr)


if __name__ == '__main__':
    main()
