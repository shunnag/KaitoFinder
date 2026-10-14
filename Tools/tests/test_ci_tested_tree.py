"""検証済み tree の省略判定と、照会失敗時の全 CI 実行を試験する。"""
import contextlib
import copy
import importlib.util
import io
import pathlib
import subprocess
import sys
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('tested_tree', pathlib.Path(__file__).resolve().parents[1] / 'ci/tested_tree.py')
tested_tree = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tested_tree)


class TestedTreeTests(unittest.TestCase):
    def setUp(self):
        self.sha, self.tree, self.head = 'a' * 40, 'b' * 40, 'e' * 40
        self.siblings = {'KaitoKit': 'c' * 40, 'GyoshukuKit': 'd' * 40}
        self.pull = {'merged_at': '2026-10-14T00:00:00Z', 'base': {'ref': 'main'},
                     'merge_commit_sha': self.sha, 'head': {'sha': self.head}}
        self.run = {'id': 123, 'event': 'pull_request', 'conclusion': 'success',
                    'head_sha': self.head, 'html_url': 'https://github.com/example/repo/actions/runs/123'}
        self.name = f"ci-tested-{self.tree}-{self.siblings['KaitoKit']}-{self.siblings['GyoshukuKit']}"
        self.artifacts = {123: [self.name]}

    def decide(self, **changes):
        arguments = dict(commit_sha=self.sha, commit_tree=self.tree, pulls=[self.pull], runs=[self.run],
                         artifact_names_by_run=self.artifacts, sibling_heads=self.siblings)
        arguments.update(changes)
        return tested_tree.decide(**arguments)

    def test_one_merged_pr_matching_tree_and_siblings_skips(self):
        skip, reason, url = self.decide()
        self.assertTrue(skip)
        self.assertTrue(reason)
        self.assertEqual(url, self.run['html_url'])

    def test_zero_or_two_merged_prs_run_full_ci(self):
        for pulls in ([], [self.pull, copy.deepcopy(self.pull)]):
            with self.subTest(pulls=pulls):
                self.assertFalse(self.decide(pulls=pulls)[0])

    def test_unmerged_wrong_base_or_wrong_merge_commit_run_full_ci(self):
        for mode in ('unmerged', 'base', 'merge'):
            pull = copy.deepcopy(self.pull)
            if mode == 'unmerged':
                pull['merged_at'] = None
            elif mode == 'base':
                pull['base']['ref'] = 'release'
            else:
                pull['merge_commit_sha'] = 'f' * 40
            with self.subTest(mode=mode):
                self.assertFalse(self.decide(pulls=[pull])[0])

    def test_tree_mismatch_or_sibling_drift_runs_full_ci(self):
        self.assertFalse(self.decide(commit_tree='f' * 40)[0])
        for name in self.siblings:
            siblings = dict(self.siblings, **{name: 'f' * 40})
            self.assertFalse(self.decide(sibling_heads=siblings)[0])
        self.assertFalse(self.decide(artifact_names_by_run={123: []})[0])

    def test_no_successful_matching_pr_run_runs_full_ci(self):
        self.assertFalse(self.decide(runs=[])[0])
        for key, value in (('conclusion', 'failure'), ('event', 'push'), ('head_sha', 'f' * 40)):
            with self.subTest(key=key):
                self.assertFalse(self.decide(runs=[dict(self.run, **{key: value})])[0])

    def test_newest_matching_record_is_selected(self):
        newer = dict(self.run, id=124, html_url='https://github.com/example/repo/actions/runs/124')
        self.assertEqual(self.decide(runs=[self.run, newer], artifact_names_by_run={123: [self.name], 124: [self.name]})[2],
                         newer['html_url'])

    def test_missing_or_error_data_runs_full_ci(self):
        for changes in ({'pulls': None}, {'runs': None}, {'artifact_names_by_run': None},
                        {'sibling_heads': {}}, {'commit_tree': ''}, {'runs': [{}]}):
            with self.subTest(changes=changes):
                self.assertFalse(self.decide(**changes)[0])

    def lookup(self, expired=False):
        endpoints = []

        def api(endpoint):
            endpoints.append(endpoint)
            if '/commits/' in endpoint:
                return [self.pull]
            if '/workflows/' in endpoint:
                return {'workflow_runs': [self.run]}
            if '/artifacts?' in endpoint:
                self.assertIn('name=' + self.name, endpoint)
                return {'artifacts': [{'name': self.name, 'expired': expired}]}
            raise AssertionError(endpoint)

        def output(*args):
            if args[0:2] == ('git', 'rev-parse'):
                return self.tree
            if args[0:2] == ('git', 'ls-remote'):
                name = 'GyoshukuKit' if '/GyoshukuKit.git' in args[2] else 'KaitoKit'
                return self.siblings[name] + '\trefs/heads/main'
            raise AssertionError(args)

        with patch.object(tested_tree, 'api', side_effect=api), patch.object(tested_tree, 'output', side_effect=output):
            result = tested_tree.lookup('example/repo', self.sha, 'ci.yml')
        self.assertIn('event=pull_request&head_sha=' + self.head + '&status=success&per_page=50', endpoints[1])
        return result

    def test_lookup_accepts_nonexpired_record_and_ignores_expired_record(self):
        self.assertTrue(self.lookup()[0])
        self.assertFalse(self.lookup(expired=True)[0])

    def test_api_or_git_error_runs_full_ci(self):
        for error in (RuntimeError('API unavailable'), subprocess.CalledProcessError(1, ['gh']),
                      subprocess.TimeoutExpired(['gh'], 30)):
            with patch.object(tested_tree, 'api', side_effect=error):
                skip, reason, url = tested_tree.lookup('example/repo', self.sha, 'ci.yml')
                self.assertFalse(skip)
                self.assertIn('全 CI', reason)
                self.assertEqual(url, '')
        with patch.object(tested_tree, 'api', return_value=[self.pull]), \
                patch.object(tested_tree, 'output', side_effect=OSError('git failed')):
            self.assertFalse(tested_tree.lookup('example/repo', self.sha, 'ci.yml')[0])

    def test_cli_lookup_error_still_outputs_false_and_exits_successfully(self):
        with patch.object(tested_tree, 'api', side_effect=RuntimeError('API unavailable')), \
                patch.object(sys, 'argv', ['tested_tree.py', 'lookup', '--repo', 'example/repo',
                                           '--sha', self.sha, '--workflow', 'ci.yml']), \
                contextlib.redirect_stdout(io.StringIO()) as stdout, contextlib.redirect_stderr(io.StringIO()):
            tested_tree.main()
        self.assertIn('skip=false\n', stdout.getvalue())
        self.assertIn('run-url=\n', stdout.getvalue())


if __name__ == '__main__':
    unittest.main()
