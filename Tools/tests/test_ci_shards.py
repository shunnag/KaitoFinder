"""CI の選択範囲と完全性の検査を外部サービスなしで試験する。"""
import contextlib
import copy
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import re
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('shards', ROOT / 'Tools/ci/shards.py')
shards = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shards)
RUNTIME_SPEC = importlib.util.spec_from_file_location('ci_runtime', ROOT / 'Tools/ci/runtime.py')
runtime = importlib.util.module_from_spec(RUNTIME_SPEC)
with patch.dict(sys.modules, {'shards': shards}):
    RUNTIME_SPEC.loader.exec_module(runtime)

SHA = 'a' * 40
TREE = 'b' * 40
SIBLINGS = {'KaitoKit': 'c' * 40, 'GyoshukuKit': 'd' * 40}


class PlanTests(unittest.TestCase):
    def test_plan_classes_exist_as_test_cases(self):
        parents = {}
        for path in (ROOT / 'KaitoFinderTests').rglob('*.swift'):
            parents.update(re.findall(r'\bclass\s+(\w+)\s*:\s*(\w+)', path.read_text()))

        def is_test_case(name, seen=None):
            seen = set() if seen is None else seen
            if name == 'XCTestCase':
                return True
            if name in seen or name not in parents:
                return False
            return is_test_case(parents[name], seen | {name})

        for plan in shards.SHARDS.values():
            for group in plan:
                for name in group:
                    self.assertTrue(is_test_case(name), name)

    def test_plan_has_no_duplicates_or_reserved_classes(self):
        self.assertEqual([len(shards.X27_S1), len(shards.M26_S1), len(shards.M26_S2)], [72, 49, 49])
        for platform, plan in shards.SHARDS.items():
            classes = [name for group in plan for name in group]
            self.assertEqual(len(classes), len(set(classes)))
            self.assertFalse(set(classes) & set(shards.EVERY_SHARD + shards.SKIP_CLASSES))
            count = len(plan) + 1
            only, skip = shards.selectors(platform, count, count)
            self.assertEqual(only, [])
            self.assertEqual(skip, list(shards.PLATFORM_SKIPS[platform]) + classes)
            for index, group in enumerate(plan, 1):
                only, skip = shards.selectors(platform, index, count)
                self.assertEqual(only, sorted(group) + list(shards.EVERY_SHARD))
                self.assertEqual(skip, list(shards.PLATFORM_SKIPS[platform]))

    def test_invalid_selection_and_plans_fail(self):
        for platform, shard, count in [('bogus', 1, 2), ('xcode-27', 1, 3), ('macos-26', 0, 3), ('macos-26', 4, 3)]:
            with self.subTest(platform=platform, shard=shard, count=count), self.assertRaises(ValueError):
                shards.selectors(platform, shard, count)
        for plan in [(('SameTests',), ('SameTests',)), (shards.EVERY_SHARD,), ((shards.SKIP_CLASSES[0],),)]:
            with patch.dict(shards.SHARDS, {'xcode-27': plan}), self.assertRaises(ValueError):
                shards.selectors('xcode-27', 1, len(plan) + 1)

    def test_representative_languages_belong_to_complete_catalog(self):
        text = (ROOT / 'KaitoFinderTests/Support/LocalizationAcceptance.swift').read_text()
        array = re.search(r'static let languages = \[(.*?)\]', text, re.S).group(1)
        languages = set(re.findall(r'"([^"]+)"', array))
        self.assertEqual(len(languages), 26)
        representative = set(shards.REPRESENTATIVE_ENV['KAITOFINDER_TEST_LANGUAGES'].split(','))
        self.assertLessEqual(representative, languages)
        self.assertLessEqual({'ja', 'en', 'zh-Hans'}, representative)
        self.assertTrue(representative & {'de', 'ru'})
        self.assertTrue(representative & {'th', 'hi'})
        self.assertEqual(shards.scope_env('representative'), shards.REPRESENTATIVE_ENV)
        self.assertEqual(shards.scope_env('full'), {})
        with self.assertRaises(ValueError):
            shards.scope_env('bogus')


class CoverageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='kaito-ci-shards-')
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.enum_path = self.root / 'enumeration.json'
        self.reports = self.root / 'reports'
        self.reports.mkdir()
        classes = {name for plan in shards.SHARDS.values() for group in plan for name in group}
        classes.update(shards.EVERY_SHARD + shards.SKIP_CLASSES + ('NewComplementTests',))
        tests = {f'KaitoFinderTests/{name}/testExample' for name in classes}
        tests.update('KaitoFinderTests/' + name for name in shards.CI_SKIP_METHODS + shards.MACOS_26_SKIP_METHODS)
        self.enumerated = {'sha': SHA, 'tree': TREE, 'siblings': SIBLINGS, 'tests': sorted(tests)}
        self.report_data = {}
        for platform, plan in shards.SHARDS.items():
            for shard in range(1, len(plan) + 2):
                if shard <= len(plan):
                    included = set(plan[shard - 1]) | set(shards.EVERY_SHARD)
                else:
                    included = classes - {name for group in plan for name in group}
                skip = set(shards.PLATFORM_SKIPS[platform])
                executed = [identifier for identifier in sorted(tests)
                            if identifier.split('/')[1] in included and identifier.split('/')[1] not in skip
                            and identifier.split('/', 1)[1] not in skip]
                self.report_data[platform, shard] = dict(
                    sha=SHA, tree=TREE, siblings=copy.deepcopy(SIBLINGS), platform=platform,
                    shard=shard, count=len(plan) + 1, scope='representative', executed=executed)
        patcher = patch.object(shards, 'git', return_value=TREE)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write_inputs(self):
        shards.write_json(self.enum_path, self.enumerated)
        for (platform, shard), data in self.report_data.items():
            folder = self.reports / f'{platform}-{shard}'
            folder.mkdir(exist_ok=True)
            shards.write_json(folder / 'shard-report.json', data)

    def verify(self):
        self.write_inputs()
        with contextlib.redirect_stdout(io.StringIO()) as stdout, contextlib.redirect_stderr(io.StringIO()):
            counts = shards.verify(self.enum_path, self.reports, self.root / 'summary.md', self.root / 'record.json')
        return counts, stdout.getvalue()

    def test_exact_coverage_and_record(self):
        counts, output = self.verify()
        self.assertEqual(output, f"record-name=ci-tested-{TREE}-{SIBLINGS['KaitoKit']}-{SIBLINGS['GyoshukuKit']}\n")
        self.assertEqual(set(counts['macos-26']), {'1', '2', '3'})
        record = json.loads((self.root / 'record.json').read_text())
        self.assertEqual(record['tree'], TREE)
        self.assertEqual(record['siblings'], SIBLINGS)
        self.assertIn('| xcode-27 | 1/2 |', (self.root / 'summary.md').read_text())

    def test_missing_id_fails(self):
        self.report_data['xcode-27', 1]['executed'].pop(0)
        with self.assertRaises(ValueError):
            self.verify()

    def test_duplicate_id_fails(self):
        executed = self.report_data['xcode-27', 1]['executed']
        executed.append(executed[0])
        with self.assertRaises(ValueError):
            self.verify()

    def test_id_in_two_shards_fails(self):
        self.report_data['xcode-27', 2]['executed'].append(self.report_data['xcode-27', 1]['executed'][0])
        with self.assertRaises(ValueError):
            self.verify()

    def test_skipped_id_running_fails(self):
        self.report_data['xcode-27', 1]['executed'].append('KaitoFinderTests/' + shards.CI_SKIP_METHODS[0])
        with self.assertRaises(ValueError):
            self.verify()

    def test_foreign_class_in_explicit_shard_fails(self):
        identifier = 'KaitoFinderTests/NewComplementTests/testExample'
        self.report_data['xcode-27', 2]['executed'].remove(identifier)
        self.report_data['xcode-27', 1]['executed'].append(identifier)
        with self.assertRaises(ValueError):
            self.verify()

    def test_stale_plan_class_fails(self):
        name = shards.X27_S1[0]
        self.enumerated['tests'] = [test for test in self.enumerated['tests'] if test.split('/')[1] != name]
        for item in self.report_data.values():
            item['executed'] = [test for test in item['executed'] if test.split('/')[1] != name]
        with self.assertRaisesRegex(ValueError, '古い shard class'):
            self.verify()

    def test_missing_process_health_class_fails(self):
        name = 'ZZProcessHealthTests'
        self.enumerated['tests'] = [test for test in self.enumerated['tests'] if test.split('/')[1] != name]
        for item in self.report_data.values():
            item['executed'] = [test for test in item['executed'] if test.split('/')[1] != name]
        with self.assertRaisesRegex(ValueError, '古い shard class.*ZZProcessHealthTests'):
            self.verify()

    def test_mismatched_tree_or_sha_fails(self):
        for key in ('tree', 'sha'):
            with self.subTest(key=key):
                self.report_data['xcode-27', 1][key] = 'e' * 40
                with self.assertRaises(ValueError):
                    self.verify()
                self.report_data['xcode-27', 1][key] = self.enumerated[key]
        with patch.object(shards, 'git', return_value='f' * 40), self.assertRaises(ValueError):
            self.verify()

    def test_missing_shard_fails(self):
        del self.report_data['macos-26', 3]
        with self.assertRaises(ValueError):
            self.verify()

    def test_duplicate_report_and_wrong_count_fail(self):
        self.write_inputs()
        folder = self.reports / 'duplicate'
        folder.mkdir()
        shards.write_json(folder / 'shard-report.json', self.report_data['xcode-27', 1])
        with self.assertRaises(ValueError):
            self.verify()
        (folder / 'shard-report.json').unlink()
        self.report_data['xcode-27', 1]['count'] = 3
        with self.assertRaises(ValueError):
            self.verify()

    def test_sibling_or_scope_drift_keeps_coverage_but_omits_record(self):
        self.verify()
        self.report_data['xcode-27', 1]['siblings']['KaitoKit'] = 'e' * 40
        _, output = self.verify()
        self.assertEqual(output, 'record-name=\n')
        self.assertFalse((self.root / 'record.json').exists())
        self.report_data['xcode-27', 1]['siblings'] = copy.deepcopy(SIBLINGS)
        self.report_data['xcode-27', 1]['scope'] = 'full'
        _, output = self.verify()
        self.assertEqual(output, 'record-name=\n')

    def test_enumeration_normalizes_and_rejects_errors_disabled_invalid_and_small_inputs(self):
        raw = self.root / 'raw.json'
        original = {'errors': [], 'values': [{'enabledTests': [
            {'identifier': f'KaitoFinderTests/ExampleTests/test{i}()'} for i in range(1000)
        ], 'disabledTests': [], 'testPlan': 'P'}]}
        with patch.object(shards, 'identity', return_value={'sha': SHA, 'tree': TREE}), \
                patch.object(shards, 'sibling_checkouts', return_value=SIBLINGS):
            shards.write_json(raw, original)
            result = shards.enumeration(raw, self.enum_path)
            self.assertEqual(len(result['tests']), 1000)
            self.assertFalse(any(test.endswith('()') for test in result['tests']))
            for mode in ('errors', 'disabled', 'invalid', 'small'):
                data = copy.deepcopy(original)
                if mode == 'errors':
                    data['errors'] = ['enumeration failed']
                elif mode == 'disabled':
                    data['values'][0]['disabledTests'] = [{'identifier': 'KaitoFinderTests/ExampleTests/testDisabled()'}]
                elif mode == 'invalid':
                    data['values'][0]['enabledTests'][0]['identifier'] = 'OtherTarget/ExampleTests/testBad()'
                else:
                    data['values'][0]['enabledTests'].pop()
                shards.write_json(raw, data)
                with self.subTest(mode=mode), self.assertRaises(ValueError):
                    shards.enumeration(raw, self.enum_path)

    def test_report_checks_log_counts_and_duplicates(self):
        log, target = self.root / 'test.log', self.root / 'report.json'
        case = "Test Case '-[KaitoFinderTests.ExampleTests testExample]' passed (0.01 seconds).\n"
        with patch.object(shards, 'identity', return_value={'sha': SHA, 'tree': TREE}), \
                patch.object(shards, 'sibling_checkouts', return_value=SIBLINGS):
            log.write_text(case + 'Executed 1 test, with 0 failures\n')
            result = shards.report('xcode-27', 1, 2, 'full', log, target, siblings_checkout=True)
            self.assertEqual(result['executed'], ['KaitoFinderTests/ExampleTests/testExample'])
            manifest = self.root / 'manifest.json'
            shards.write_json(manifest, {'repos': {name: {'sha': sha} for name, sha in SIBLINGS.items()}})
            result = shards.report('macos-26', 1, 3, 'representative', log, target, siblings_manifest=manifest)
            self.assertEqual(result['siblings'], SIBLINGS)
            for text in ('Executed 0 tests, with 0 failures\n', case + 'Executed 2 tests, with 0 failures\n',
                         case * 2 + 'Executed 2 tests, with 0 failures\n', case):
                log.write_text(text)
                with self.subTest(text=text), self.assertRaises(ValueError):
                    shards.report('xcode-27', 1, 2, 'full', log, target, siblings_checkout=True)


class RuntimeTests(unittest.TestCase):
    def test_guard_accepts_both_forms_and_rejects_failures_zero_and_silent_skip(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = pathlib.Path(temporary) / 'tests.log'
            for text in ('Executed 3 tests, with 0 failures', 'Executed 3 tests, with 1 test skipped and 0 failures',
                         'Executed 3 tests, with 2 tests skipped and 0 failures'):
                log.write_text(text)
                with contextlib.redirect_stdout(io.StringIO()):
                    runtime.guard(log)
            for text in ('Executed 3 tests, with 1 failure', 'Executed 3 tests, with 1 test skipped and 1 failure',
                         'Executed 0 tests, with 0 failures', 'no summary',
                         'Executed 3 tests, with 0 failures\nRequired fixture tool is unavailable',
                         'Executed 3 tests, with 0 failures\n7zz is not installed'):
                log.write_text(text)
                with self.subTest(text=text), self.assertRaises(RuntimeError):
                    runtime.guard(log)

    def test_patch_selectors_scope_and_manifest_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            products, runtime_path = root / 'Products', root / 'ci-runtime'
            products.mkdir()
            runtime_path.mkdir()
            shards.write_json(runtime_path / 'manifest.json', {'shards': {'platform': 'macos-26', 'count': 3}})
            data = {'__xctestrun_metadata__': {'FormatVersion': 1}, 'KaitoFinderTests': {
                'IsAppHostedTestBundle': True, 'TestHostPath': '__TESTROOT__/Debug/KaitoFinder.app',
                'TestBundlePath': '__TESTHOST__/Contents/PlugIns/KaitoFinderTests.xctest',
                'OnlyTestIdentifiers': ['StaleTests'], 'SkipTestIdentifiers': ['ExistingTests'],
                'TestingEnvironmentVariables': dict(shards.REPRESENTATIVE_ENV)}}
            (products / 'KaitoFinder_test.xctestrun').write_bytes(plistlib.dumps(data))
            for shard, scope in ((1, 'representative'), (3, 'full')):
                with patch.object(runtime.subprocess, 'run'), contextlib.redirect_stdout(io.StringIO()):
                    runtime.patch(products, runtime_path, shard, 3, scope)
                tests = plistlib.loads((products / 'ci-macos-26.xctestrun').read_bytes())['KaitoFinderTests']
                only, skip = shards.selectors('macos-26', shard, 3)
                self.assertEqual(tests.get('OnlyTestIdentifiers', []), only)
                self.assertEqual(tests['SkipTestIdentifiers'], ['ExistingTests'] + skip)
                for key in shards.REPRESENTATIVE_ENV:
                    self.assertEqual(tests['TestingEnvironmentVariables'].get(key), shards.scope_env(scope).get(key))
            with self.assertRaises(RuntimeError):
                runtime.patch(products, runtime_path, 1, 2, 'full')

    def test_direct_refuses_missing_configuration(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runtime.subprocess, 'Popen') as process:
            path = pathlib.Path(temporary)
            with self.assertRaisesRegex(RuntimeError, 'Missing pre-generated'):
                runtime.direct(path, path, 1, 1, 'representative')
            process.assert_not_called()


if __name__ == '__main__':
    unittest.main()
