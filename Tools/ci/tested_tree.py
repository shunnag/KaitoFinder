#!/usr/bin/env python3
"""同じ tree と兄弟 SHA が PR で検証済みなら main の重い CI を省く。"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlencode


SIBLINGS = ("KaitoKit", "GyoshukuKit")


def merged_pulls(commit_sha, pulls):
    return [pull for pull in pulls if pull.get("merged_at") and pull["base"]["ref"] == "main"
            and pull["merge_commit_sha"] == commit_sha]


def decide(commit_sha, commit_tree, pulls, runs, artifact_names_by_run, sibling_heads):
    try:
        candidates = merged_pulls(commit_sha, pulls)
        if len(candidates) != 1:
            return False, "一致する merged PR が一つではありません", ""
        head = candidates[0]["head"]["sha"]
        if not all(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha)
                   for sha in (commit_sha, commit_tree, head, *(sibling_heads[name] for name in SIBLINGS))):
            return False, "tree または SHA が不足・不正です", ""
        expected = f"ci-tested-{commit_tree}-{sibling_heads['KaitoKit']}-{sibling_heads['GyoshukuKit']}"
        for run in sorted(runs, key=lambda item: int(item["id"]), reverse=True):
            if run["event"] != "pull_request" or run["conclusion"] != "success" or run["head_sha"] != head:
                continue
            if expected in artifact_names_by_run[run["id"]] and run["html_url"]:
                return True, "同じ tree と兄弟 SHA は PR で検証済みです", run["html_url"]
        return False, "同じ tree と兄弟 SHA の成功記録がありません", ""
    except Exception as error:
        return False, f"照会データの不足・エラーにより全 CI を実行します: {error}", ""


def output(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def api(endpoint):
    return json.loads(output("gh", "api", endpoint))


def lookup(repo, sha, workflow):
    try:
        pulls = api(f"repos/{repo}/commits/{sha}/pulls")
        candidates = merged_pulls(sha, pulls)
        if len(candidates) != 1:
            return False, "一致する merged PR が一つではありません", ""
        tree = output("git", "rev-parse", f"{sha}^{{tree}}")
        query = urlencode({"event": "pull_request", "head_sha": candidates[0]["head"]["sha"],
                           "status": "success", "per_page": 50})
        runs = api(f"repos/{repo}/actions/workflows/{workflow}/runs?{query}")["workflow_runs"]
        sibling_heads = {}
        for name in SIBLINGS:
            remote = output("git", "ls-remote", f"https://github.com/shunnag/{name}.git", "refs/heads/main")
            remote_sha, ref = remote.split()
            if ref != "refs/heads/main" or not re.fullmatch(r"[0-9a-f]{40}", remote_sha):
                raise ValueError(f"兄弟 main の SHA が不正です: {name}")
            sibling_heads[name] = remote_sha
        expected = f"ci-tested-{tree}-{sibling_heads['KaitoKit']}-{sibling_heads['GyoshukuKit']}"
        artifact_names = {}
        for run in sorted(runs, key=lambda item: int(item["id"]), reverse=True):
            artifacts = api(f"repos/{repo}/actions/runs/{run['id']}/artifacts?" + urlencode({"name": expected}))["artifacts"]
            artifact_names[run["id"]] = [item["name"] for item in artifacts if item["expired"] is False]
            decision = decide(sha, tree, pulls, [run], artifact_names, sibling_heads)
            if decision[0]:
                return decision
        return decide(sha, tree, pulls, runs, artifact_names, sibling_heads)
    except Exception as error:
        return False, f"照会に失敗したため全 CI を実行します: {error}", ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("lookup")
    command.add_argument("--repo", required=True)
    command.add_argument("--sha", required=True)
    command.add_argument("--workflow", required=True)
    args = parser.parse_args()
    skip, reason, run_url = lookup(args.repo, args.sha, args.workflow)
    reason = " ".join(reason.splitlines())
    run_url = " ".join(run_url.splitlines())
    print("skip=" + str(skip).lower())
    print("reason=" + reason)
    print("run-url=" + run_url)
    message = f"main の CI 判定: {reason}。" + (f" PR run: {run_url}" if run_url else "") + "\n"
    print(message, file=sys.stderr, end="")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        try:
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as stream:
                stream.write(message)
        except OSError as error:
            print(f"job summary を書けませんでした: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
