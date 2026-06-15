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


def get_activity_via_timeline(org, repo, epic_number, since):
    """Check timeline for cross-referenced PRs merged since the given date."""
    try:
        result = subprocess.run(
            ['gh', 'api', f'repos/{org}/{repo}/issues/{epic_number}/timeline',
             '--paginate', '--jq',
             f'.[] | select(.event == "cross-referenced") | select(.source.issue.pull_request != null) | select(.source.issue.state == "closed") | .source.issue.number'],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            return {'prs_merged': 0, 'issues_closed': 0, 'pr_numbers': []}
        numbers = [int(n) for n in result.stdout.strip().split('\n') if n.strip()]
        return {
            'prs_merged': len(numbers),
            'issues_closed': 0,
            'pr_numbers': numbers,
        }
    except (subprocess.TimeoutExpired, ValueError):
        return {'prs_merged': 0, 'issues_closed': 0, 'pr_numbers': []}


def query_projects_v2_status(org):
    """Query GitHub Projects v2 for epic statuses. Returns {issue_url: status} map."""
    query = """
    query($org: String!) {
      organization(login: $org) {
        projectsV2(first: 20) {
          nodes {
            title
            number
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
    }
    """
    result = subprocess.run(
        ['gh', 'api', 'graphql', '-F', f'org={org}', '-f', f'query={query}'],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        return None

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None

    status_map = {}
    projects = data.get('data', {}).get('organization', {}).get('projectsV2', {}).get('nodes', [])
    for project in projects:
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

        status = ""
        if status_map and url in status_map:
            status = status_map[url]

        activity = get_activity_via_timeline(args.org, epic['repo'], epic['number'], since)
        has_activity = activity['prs_merged'] > 0
        updated_in_period = updated_at >= since

        if not fallback_mode and status_map:
            is_in_progress = status.lower() in ('in progress', 'in-progress', 'active')
            if not is_in_progress and not has_activity:
                continue
        else:
            if not updated_in_period and not has_activity:
                continue
            status = "Active" if has_activity else "Updated"

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
            'updated_at': updated_at,
            'labels': labels,
        })

    results.sort(key=lambda e: (
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
